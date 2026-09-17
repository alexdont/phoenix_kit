defmodule PhoenixKitWeb.Components.Core.ChartLanesTest do
  @moduledoc """
  `chart_lanes/1` — rows of bands on a chart's x axis.

  What a caller relies on: a band sits at the same percentage of the width as
  the chart's x (same scale), bands outside the domain or empty are not
  drawn, open ends run to the edge, the component owns no vocabulary beyond
  how a band is drawn, and every row still reads to a screen reader.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.ChartLanes

  # A band is its positioned wrapper (colour class, placement, title) and the
  # shape inside it (the variant's classes).
  defp bands(html) do
    ~r{<div class="([^"]*)" style="left: ([0-9.]+)%; width: ([0-9.]+)(%|px)"(?: title="([^"]*)")?[^>]*>\s*<span class="absolute inset-0 rounded-sm ([^"]*)"}
    |> Regex.scan(html)
    |> Enum.map(fn [_, class, left, width, unit, title, shape] ->
      %{
        class: class <> " " <> shape,
        left: String.to_float(left),
        width: if(unit == "%", do: String.to_float(width), else: {:px, width}),
        title: if(title == "", do: nil, else: title)
      }
    end)
  end

  defp render(rows, extra \\ %{}) do
    assigns = Map.merge(%{rows: rows, domain: {0, 1440}, marker: nil, scroll: 12}, extra)

    rendered_to_string(~H"""
    <.chart_lanes
      id="l"
      rows={@rows}
      x_domain={@domain}
      marker_x={@marker}
      scroll_after={@scroll}
    />
    """)
  end

  test "a band sits where the chart's scale puts its range" do
    html = render([%{label: "Boiler", bands: [%{from: 360, to: 720, title: "On"}]}])

    assert [%{left: 25.0, width: 25.0, title: "On"}] = bands(html)
    assert html =~ "Boiler"
  end

  test "open ends run to the domain's edges; outside, backwards and non-numeric bands are dropped" do
    html =
      render([
        %{
          label: "R",
          bands: [
            %{from: nil, to: 144},
            %{from: 1296, to: nil},
            %{from: 2000, to: 3000},
            %{from: 600, to: 400},
            %{from: "soon", to: 700},
            :not_a_band
          ]
        }
      ])

    assert [%{left: +0.0, width: 10.0}, %{left: 90.0, width: 10.0}] = bands(html)
  end

  test "variants are visual only; colour is the caller's class; unknown variants fill" do
    html =
      render([
        %{
          label: "R",
          bands: [
            %{from: 0, to: 100, variant: :dashed, class: "text-info"},
            %{from: 0, to: 100, variant: "outline"},
            %{from: 0, to: 100, variant: :soft},
            %{from: 0, to: 100, variant: :planned}
          ]
        }
      ])

    [dashed, outline, soft, unknown] = bands(html)
    assert dashed.class =~ "border-dashed"
    assert dashed.class =~ "text-info"
    assert outline.class =~ "border-2 border-current"
    refute outline.class =~ "dashed"
    assert soft.class =~ "opacity-25"
    assert unknown.class =~ "bg-current opacity-70"
  end

  test "later bands are drawn after earlier ones, so they sit on top" do
    html =
      render([
        %{
          label: "R",
          bands: [%{from: 0, to: 720, title: "first"}, %{from: 100, to: 200, title: "second"}]
        }
      ])

    assert Enum.map(bands(html), & &1.title) == ["first", "second"]
  end

  test "a band without a title reads as its range, through x_format" do
    assigns = %{fmt: fn minutes -> "#{div(minutes, 60)}h" end}

    html =
      rendered_to_string(~H"""
      <.chart_lanes
        id="l"
        x_domain={{0, 1440}}
        x_format={@fmt}
        rows={[%{label: "R", bands: [%{from: 60, to: 120}, %{from: 1380, to: nil}]}]}
      />
      """)

    assert Enum.map(bands(html), & &1.title) == ["1h–2h", "23h–24h"]
    assert html =~ ~s(<span class="sr-only">R, 1h–2h, 23h–24h</span>)
  end

  test "rows accept string keys and Decimal ranges" do
    html =
      render([
        %{
          "label" => "Room 1",
          "note" => "busy",
          "bands" => [%{"from" => Decimal.new("720"), "to" => Decimal.new("1080")}]
        }
      ])

    assert [%{left: 50.0, width: 25.0}] = bands(html)
    assert html =~ "Room 1"
    assert html =~ "busy"
  end

  test "the marker is drawn inside the domain only" do
    assert render([%{label: "R", bands: []}], %{marker: 720}) =~ "left: 50.0%"
    refute render([%{label: "R", bands: []}], %{marker: 2000}) =~ "border-l border-dashed"
  end

  test "the list scrolls only past scroll_after rows" do
    rows = for i <- 1..3, do: %{label: "R#{i}", bands: []}

    refute render(rows, %{scroll: 3}) =~ "overflow-y-auto"

    html = render(rows, %{scroll: 2})
    assert html =~ "overflow-y-auto"
    assert html =~ "max-height: 4rem"

    refute render(rows, %{scroll: nil}) =~ "overflow-y-auto"
  end

  test "row DOM ids follow the caller's ids, stay unique, and fall back to the position" do
    html =
      render([
        %{id: "boiler 1", label: "A", bands: []},
        %{id: "boiler 1", label: "B", bands: []},
        %{label: "C", bands: []}
      ])

    assert html =~ ~s(id="l-row-boiler_1")
    assert html =~ ~s(id="l-row-boiler_1-1")
    assert html =~ ~s(id="l-row-i2")

    reordered = render([%{id: "b", label: "B", bands: []}, %{id: "a", label: "A", bands: []}])
    assert reordered =~ ~r{id="l-row-b"[^>]*>.*B.*id="l-row-a"}s
  end

  test "the marker and gridlines are drawn inside every row, with the bands" do
    html =
      render([%{label: "R1", bands: []}, %{label: "R2", bands: []}], %{marker: 720})

    assert length(Regex.scan(~r{border-dashed border-current[^"]*" style="left: 50.0%"}, html)) ==
             2
  end

  test "a point (from == to) is a thin centred mark titled with its x" do
    assigns = %{fmt: fn minutes -> "#{div(minutes, 60)}h" end}

    html =
      rendered_to_string(~H"""
      <.chart_lanes
        id="l"
        x_domain={{0, 1440}}
        x_format={@fmt}
        rows={[%{label: "R", bands: [%{from: 720, to: 720}, %{from: 2000, to: 2000}]}]}
      />
      """)

    assert [%{left: 50.0, width: {:px, "3"}, title: "12h", class: class}] = bands(html)
    assert class =~ "-translate-x-1/2"
  end

  test "a band label is drawn inside the band and becomes its title" do
    html = render([%{label: "Room", bands: [%{from: 0, to: 720, label: "Ada Lovelace"}]}])

    assert [%{title: "Ada Lovelace"}] = bands(html)
    assert html =~ ~r{<span class="relative px-1[^"]*">\s*Ada Lovelace\s*</span>}
  end

  test "the band slot receives the caller's band, and bands stay readable to assistive tech" do
    assigns = %{rows: [%{label: "Room", bands: [%{from: 0, to: 60, id: "b1", label: "Ada"}]}]}

    html =
      rendered_to_string(~H"""
      <.chart_lanes id="l" rows={@rows} x_domain={{0, 1440}}>
        <:band :let={band}><button phx-click="open" phx-value-id={band.id}>{band.label}</button></:band>
      </.chart_lanes>
      """)

    assert html =~ ~s(<button phx-click="open" phx-value-id="b1">Ada</button>)

    refute html =~ ~s(class="absolute inset-0" aria-hidden="true"),
           "a layer holding controls is not hidden"

    plain = render([%{label: "Room", bands: [%{from: 0, to: 60}]}])
    assert plain =~ ~s(class="absolute inset-0" aria-hidden="true")
  end

  test "ticks draw gridlines inside the domain only" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.chart_lanes id="l" x_domain={{0, 24}} ticks={[6, 12, 18, 30]} rows={[%{label: "R", bands: []}]} />
      """)

    lines = Regex.scan(~r{border-l border-base-content/10[^"]*" style="left: ([0-9.]+)%"}, html)
    assert Enum.map(lines, fn [_, left] -> left end) == ["25.0", "50.0", "75.0"]
  end

  test "no rows, or no usable domain, renders the empty slot" do
    assigns = %{}

    for domain <- [{0, 10}, {nil, nil}] do
      rows = if domain == {0, 10}, do: [], else: [%{label: "R", bands: []}]
      assigns = Map.merge(assigns, %{rows: rows, domain: domain})

      html =
        rendered_to_string(~H"""
        <.chart_lanes id="l" rows={@rows} x_domain={@domain}>
          <:empty>Nothing scheduled</:empty>
        </.chart_lanes>
        """)

      assert html =~ "Nothing scheduled"
      refute html =~ "<ul"
    end
  end

  test "a custom row label receives the caller's row" do
    assigns = %{rows: [%{label: "Room 7", path: "/rooms/7", bands: []}]}

    html =
      rendered_to_string(~H"""
      <.chart_lanes id="l" rows={@rows} x_domain={{0, 1}}>
        <:row_label :let={row}><a href={row.path}>{row.label}</a></:row_label>
      </.chart_lanes>
      """)

    assert html =~ ~s(<a href="/rooms/7">Room 7</a>)
  end
end
