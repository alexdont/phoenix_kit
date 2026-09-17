defmodule PhoenixKit.Integration.RealManifestShapesTest do
  @moduledoc """
  The real `ExpectedSchema` manifest against the suite's own freshly migrated
  database — the part of `dev_docs/squash/verify.exs`'s S8 ("a freshly
  installed chain must yield an empty repair plan") that `mix test` can run.

  Hand-declared manifest entries are where the manifest and the chain drift
  apart, and nothing else in the suite compares them. Two such drifts went
  unnoticed until S8 was run by hand: the V170 notification indexes carried
  their expression keys in the full definition's doubled parentheses (so every
  healthy install reported them as the wrong shape), and the settings seeds
  that V184 and V189 delete were still required (so `mix phoenix_kit.repair`
  put them back).
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  defp required(class) do
    for %{class: ^class, presence: :required} = object <- ExpectedSchema.objects("public"),
        do: object
  end

  # The shape a database at the chain head must have: the newest revision.
  defp newest_shape(%{revisions: revisions}) do
    {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
    shape
  end

  test "every required index exists with the shape the repair probe reads" do
    snapshot = Probe.snapshot(Repo, "public")

    problems =
      for object <- required(:index),
          problem = index_problem(object, Probe.lookup(snapshot, object.check)),
          do: {object.id, problem}

    assert problems == []
  end

  # Best-effort seeders (a Mix task the migration calls when it can) are not
  # guaranteed present by design; every other required seed is.
  test "every required seed exists after the chain has run" do
    missing =
      for object <- required(:seed),
          not Map.get(newest_shape(object), :best_effort, false),
          not Probe.seed_present?(Repo, object.check),
          do: object.id

    assert missing == []
  end

  test "a seed the chain deletes is optional and never re-created" do
    for key <- ~w(billing_default_currency shop_currency) do
      object =
        Enum.find(
          ExpectedSchema.objects("public"),
          &(&1.id == "seed:phoenix_kit_settings:#{key}")
        )

      assert %{presence: :legacy_optional, create: nil} = object
      refute Probe.seed_present?(Repo, object.check), "#{key} is deleted by the chain"
    end
  end

  defp index_problem(_object, nil), do: :missing

  defp index_problem(object, observed) do
    case Differ.compare(:index, newest_shape(object), observed) do
      :match ->
        nil

      {:mismatch, _} = mismatch ->
        # Definition text rendered by another Postgres major is not a shape
        # difference; the repair engine reports it the same way.
        if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
    end
  end
end
