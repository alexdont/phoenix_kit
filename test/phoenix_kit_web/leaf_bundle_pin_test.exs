defmodule PhoenixKitWeb.LeafBundlePinTest do
  @moduledoc """
  Holds the Leaf CDN pin and the Leaf dependency together.

  phoenix_kit.js lazy-loads Leaf's editor bundle from a pinned jsdelivr tag,
  while mix.exs resolves the Elixir half from Hex. The two halves are one
  contract: a bundle left behind renders an identical editor while quietly not
  implementing what the server now expects — no error, just events that never
  arrive. The comment at the pin cited this test for years before it existed;
  now it does.
  """
  use ExUnit.Case, async: true

  @bundle Path.join([__DIR__, "..", "..", "priv", "static", "assets", "phoenix_kit.js"])

  defp pinned_version do
    contents = File.read!(@bundle)

    case Regex.run(~r{cdn\.jsdelivr\.net/gh/[^/]+/leaf@v([0-9]+\.[0-9]+\.[0-9]+)/}, contents) do
      [_, version] -> version
      nil -> flunk("no leaf@vX.Y.Z pin found in #{@bundle}")
    end
  end

  defp locked_version do
    case File.read!(Path.join([__DIR__, "..", "..", "mix.lock"]))
         |> then(&Regex.run(~r/"leaf": \{:hex, :leaf, "([0-9]+\.[0-9]+\.[0-9]+)"/, &1)) do
      [_, version] -> version
      nil -> flunk("leaf is not locked in mix.lock")
    end
  end

  test "the CDN pin is the version the Elixir half is locked to" do
    assert pinned_version() == locked_version(),
           """
           priv/static/assets/phoenix_kit.js pins leaf@v#{pinned_version()} while \
           mix.lock resolves leaf #{locked_version()}. Browsers would run one \
           version of the editor against the other version's server half. \
           Update the LEAF_CDN constant and the lock together.
           """
  end

  test "the pinned version is one mix.exs permits" do
    requirement =
      File.read!(Path.join([__DIR__, "..", "..", "mix.exs"]))
      |> then(&Regex.run(~r/\{:leaf, "([^"]+)"/, &1))
      |> case do
        [_, req] -> req
        nil -> flunk("no :leaf requirement found in mix.exs")
      end

    assert Version.match?(pinned_version(), requirement),
           "the pin (#{pinned_version()}) falls outside the mix.exs requirement (#{requirement})"
  end
end
