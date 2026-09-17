defmodule PhoenixKit.Migrations.VersionCommentTest do
  @moduledoc """
  Every `vNNN.ex` that stamps the `phoenix_kit` table's version comment
  must stamp `NNN` (its `up/1`) and nothing but `NNN` or `NNN - 1` (its
  `down/1`).

  A migration renumbered while merging (V191 → V192 in PR #820, after
  main took V191) keeps its old comment strings unless someone rewrites
  them by hand — and a single-step `up` leaves the stale value behind,
  since `Postgres.handle_version_recording/4` only restamps multi-step
  runs.
  """

  use ExUnit.Case, async: true

  @dir Path.expand("../../../lib/phoenix_kit/migrations/postgres", __DIR__)

  test "version comments match the file's own version number" do
    files = Path.wildcard(Path.join(@dir, "v*.ex"))
    assert files != [], "no migration files found under #{@dir}"

    for file <- files,
        [_, digits] = Regex.run(~r/v(\d+)\.ex$/, file),
        n = String.to_integer(digits),
        stamped =
          Regex.scan(~r/phoenix_kit IS '(\d+)'/, File.read!(file))
          |> Enum.map(fn [_, v] -> String.to_integer(v) end)
          |> Enum.uniq(),
        stamped != [] do
      assert n in stamped,
             "#{Path.basename(file)} never stamps '#{n}' — got #{inspect(stamped)}"

      assert Enum.all?(stamped, &(&1 in [n, n - 1])),
             "#{Path.basename(file)} stamps #{inspect(stamped)}; only #{n} (up) " <>
               "and #{n - 1} (down) belong there"
    end
  end
end
