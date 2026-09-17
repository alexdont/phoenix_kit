defmodule PhoenixKitWeb.Components.Core.ChartScaleTest do
  @moduledoc """
  `ChartScale` — the x scale `line_chart/1` draws with, public so an overlay
  can sit exactly over a chart. The line chart now uses it itself, so the
  last test pins the two together.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Chart

  alias PhoenixKitWeb.Components.Core.ChartScale

  doctest ChartScale

  describe "domain/2" do
    test "an explicit domain wins, a reversed one is swapped" do
      assert ChartScale.domain({0, 1440}, [5, 10]) == {0, 1440}
      assert ChartScale.domain({Decimal.new("10"), 0}, []) == {0, 10.0}
    end

    test "an unusable explicit bound falls back to the data, not to a constant" do
      assert ChartScale.domain({nil, 99}, [3, 7, "x", nil]) == {3, 7}
      assert ChartScale.domain(:bogus, [2]) == {2, 2}
      assert ChartScale.domain(nil, ["a"]) == nil
    end
  end

  describe "span/3" do
    test "clips to the domain" do
      assert ChartScale.span({0, 100}, -50, 25) == %{left: 0.0, width: 25.0}
      assert ChartScale.span({0, 100}, 75, 500) == %{left: 75.0, width: 25.0}
    end

    test "open bounds run to the edges" do
      assert ChartScale.span({0, 200}, nil, nil) == %{left: 0.0, width: 100.0}
      assert ChartScale.span({0, 200}, nil, 50) == %{left: 0.0, width: 25.0}
    end

    test "nothing to draw is nil" do
      assert ChartScale.span({0, 100}, 50, 50) == nil
      assert ChartScale.span({0, 100}, 60, 40) == nil
      assert ChartScale.span({0, 100}, -20, -10) == nil
      assert ChartScale.span({0, 100}, "10", 20) == nil
      assert ChartScale.span({5, 5}, 1, 9) == nil
    end
  end

  test "a degenerate domain centres every value, as the chart does" do
    assert ChartScale.fraction({5, 5}, 123) == 0.5
    assert ChartScale.percent({5, 5}, -1) == 50.0
  end

  test "the line chart places x exactly where the scale says" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart
        id="c"
        data={[{0, 1}, {360, 2}, {1440, 3}]}
        x_domain={{0, 1440}}
        area={false}
        width={1000}
      />
      """)

    # 360 of 0..1440 is 25% of a 1000-wide viewBox.
    assert html =~ "L#{ChartScale.percent({0, 1440}, 360) * 10},"
  end
end
