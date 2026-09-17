defmodule PhoenixKit.Migrations.Repair.EnvironmentProbeTest do
  @moduledoc """
  The behavioral pooler probe against the real test database.

  The test database is reached directly, so two statements on one checkout
  land on the same backend: the probe must say `:not_detected` — and must not
  claim more than that, since a session pooler looks the same. A probe that
  cannot run says `{:inconclusive, reason}`; only `pooled?/1`, which guards
  repairs, folds that into "pooled".
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Migrations.Repair.Environment

  test "a direct connection shows no transaction pooling" do
    assert Environment.probe(Repo) == :not_detected
    refute Environment.pooled?(Repo)
  end

  defmodule BrokenRepo do
    def checkout(_fun), do: raise("connection refused")
  end

  test "a probe that cannot run is inconclusive, and repair still treats it as pooled" do
    assert {:inconclusive, reason} = Environment.probe(BrokenRepo)
    assert reason =~ "connection refused"
    assert Environment.pooled?(BrokenRepo), "an unprovable environment must stay the safe answer"
  end
end
