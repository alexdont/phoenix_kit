defmodule PhoenixKitWeb.Components.Core.ChartHoverTest do
  @moduledoc """
  `line_chart hover` — a hover readout without JavaScript.

  `bar_chart` already put each bar's formatted value in a native tooltip;
  `line_chart` had nothing, so a host that wanted "what was the price at
  14:00?" layered its own hook over a deliberately stretched SVG. The line
  chart now draws one invisible band per point (the x the point stands for),
  each with a tooltip and the raw values in `data-*` for a host hook to use.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Chart

  defp bands(html) do
    ~r{<rect x="([^"]+)" y="0" width="([^"]+)"[^>]*data-x="([^"]+)" data-y="([^"]+)"[^>]*>\s*<title>([^<]*)</title>}
    |> Regex.scan(html)
    |> Enum.map(fn [_, x, w, dx, dy, title] ->
      %{x: String.to_float(x), w: String.to_float(w), data_x: dx, data_y: dy, title: title}
    end)
  end

  test "no bands unless hover is asked for" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 2}]} />
      """)

    refute html =~ "data-x="
  end

  test "step data: each band runs from its x to the next, the last to the edge" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 10}, {1, 20}, {2, 30}]} x_domain={{0, 4}} step hover width={400} />
      """)

    assert [a, b, c] = bands(html)
    assert {a.x, a.w} == {0.0, 100.0}
    assert {b.x, b.w} == {100.0, 100.0}
    assert {c.x, c.w} == {200.0, 200.0}, "the last value holds to the domain's right edge"
  end

  test "point data: bands meet half-way between neighbours and cover the chart" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 10}, {2, 20}, {4, 30}]} hover width={400} />
      """)

    assert [a, b, c] = bands(html)
    assert a.x == 0.0
    assert a.x + a.w == b.x
    assert b.x + b.w == c.x
    assert c.x + c.w == 400.0
  end

  test "the tooltip formats the value, and the x when asked" do
    assigns = %{fmt: &"€#{&1}", xfmt: &"#{&1}:00"}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{14, 0.25}]} hover value_format={@fmt} x_format={@xfmt} />
      """)

    assert [band] = bands(html)
    assert band.title == "14:00: €0.25"
    assert {band.data_x, band.data_y} == {"14", "0.25"}
  end

  test "a lone point answers across the whole chart, with or without step" do
    for step <- [true, false] do
      assigns = %{step: step}

      html =
        rendered_to_string(~H"""
        <.line_chart id="c" data={[{0, 5}]} step={@step} hover width={400} />
        """)

      assert [band] = bands(html), "step=#{step}: one band"
      assert {band.x, band.w} == {0.0, 400.0}, "step=#{step}"
      assert band.data_y == "5"
    end
  end

  test "points sharing the only x: the last one answers" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{3, 1}, {3, 9}]} hover width={400} />
      """)

    assert [band] = bands(html)
    assert {band.x, band.w, band.data_y} == {0.0, 400.0, "9"}
  end

  test "x_format gets the plotted number — the documented clock example works" do
    assigns = %{
      clock: fn minutes ->
        :io_lib.format("~2..0B:~2..0B", [div(minutes, 60), rem(minutes, 60)])
        |> IO.iodata_to_binary()
      end
    }

    html =
      rendered_to_string(~H"""
      <.line_chart
        id="c"
        data={[{810, 0.25}, {840, 0.3}]}
        x_domain={{0, 1440}}
        step
        hover
        x_format={@clock}
      />
      """)

    assert [first, _] = bands(html)
    assert first.title == "13:30: 0.25"
  end

  test "a duplicate x gets no zero-width band" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 2}, {1, 3}, {2, 4}]} step hover />
      """)

    assert Enum.all?(bands(html), &(&1.w > 0))
  end

  test "bands are transparent-filled so they receive the pointer" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 2}]} hover />
      """)

    assert html =~ ~s(fill="transparent" data-x=)
    refute html =~ ~r{<rect[^>]*fill="none"[^>]*data-x=}
  end
end
