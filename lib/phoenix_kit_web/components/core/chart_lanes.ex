defmodule PhoenixKitWeb.Components.Core.ChartLanes do
  @moduledoc """
  Rows of horizontal bands on a chart's x axis — what was scheduled, on or
  booked over the stretch a chart above shows. No JavaScript.

  A row is one thing (a device, a room, a person, a task); its bands are the
  stretches of x it occupies. Bands say nothing about what they mean: each
  carries a `variant` (how it is drawn) and a `class` (its colour), and the
  caller decides which of its own states map to which. Layer several bands in
  one row to show, say, a planned window as a dashed outline with the
  actually used part filled inside it.

  ## Lining up with a chart

  Bands are placed in percentages of the lanes' width with
  `PhoenixKitWeb.Components.Core.ChartScale` — the scale `line_chart/1`
  draws with. Give both the same `x_domain` and the same width (one wrapper,
  no padding between them) and every band sits under the chart's x:

      <div class="w-full">
        <div class="h-48">
          <.line_chart id="price" data={@prices} x_domain={{0, 1440}} step />
        </div>
        <.chart_lanes id="devices" rows={@device_rows} x_domain={{0, 1440}} marker_x={@now} />
      </div>

  Bands are HTML, not SVG, so dashed borders and rounded ends keep their
  shape however wide the page is.

  ## Scrolling

  With more rows than `scroll_after`, the list scrolls inside a fixed
  height while the chart above stays put. A classic (non-overlay) scrollbar
  takes a few pixels from the right edge of the scrolling list; when exact
  alignment matters at the right edge, give the chart the same right padding
  or set `scroll_after={nil}` and let the page scroll.

  Origin: generalised from NordSwitch's device schedule under its price
  chart.
  """

  use Phoenix.Component

  alias PhoenixKitWeb.Components.Core.ChartScale

  @variants %{
    "fill" => "bg-current opacity-70",
    "soft" => "bg-current opacity-25",
    "outline" => "border-2 border-current",
    "dashed" => "border-2 border-dashed border-current"
  }

  @doc """
  Renders rows of bands on a shared x axis.

  ## Rows

  Each row is a map:

    * `:id` — optional stable id; the row's DOM id follows it, so a reordered
      list keeps each row's element
    * `:label` — what the row is (rendered over the row unless the
      `:row_label` slot is given)
    * `:note` — optional secondary text beside the label
    * `:bands` — a list of bands

  Each band is a map:

    * `:from`, `:to` — x values, in the chart's units. `nil` is open-ended and
      runs to that edge of the domain. `from == to` is a point (a milestone,
      an event) and is drawn as a thin mark. A band outside the domain or
      running backwards is not drawn.
    * `:variant` — `:fill` (default), `:soft`, `:outline` or `:dashed`
    * `:class` — its colour, as a text colour class (`"text-primary"`)
    * `:label` — optional text inside the band (a guest name on a booking)
    * `:title` — the native tooltip and the screen-reader text; defaults to
      the label, then the range through `x_format`

  Bands are drawn in list order, so later bands sit on top. Any other keys
  are kept and handed to the `:band` slot.

  ## Interactive bands

  The `:band` slot renders inside each band and receives the band's own map,
  so a band can hold a real link or button — the accessible way to make it
  open a booking or a task:

      <.chart_lanes id="bookings" rows={@rows} x_domain={{8, 20}}>
        <:band :let={band}>
          <button type="button" phx-click="open" phx-value-id={band.id} class="w-full h-full text-left px-1 truncate">
            {band.label}
          </button>
        </:band>
      </.chart_lanes>

  ## Examples

      <.chart_lanes
        id="boilers"
        x_domain={{0, 1440}}
        marker_x={@now_minute}
        x_format={&clock_label/1}
        rows={[
          %{label: "Office boiler", note: "22 °C",
            bands: [
              %{from: 360, to: 540, variant: :dashed, class: "text-info", title: "Scheduled"},
              %{from: 380, to: 470, variant: :fill, class: "text-success", title: "Heating"}
            ]}
        ]}
      />

      <%!-- a custom label --%>
      <.chart_lanes id="rooms" rows={@rooms} x_domain={{8, 20}}>
        <:row_label :let={row}><.link navigate={row.path}>{row.label}</.link></:row_label>
      </.chart_lanes>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true, doc: "Rows, each `%{id, label, note, bands}` (see above)"

  attr :x_domain, :any,
    required: true,
    doc:
      "`{low, high}` — pass the chart's own `x_domain` so bands line up with it. " <>
        "Required: bands alone cannot say where the axis starts and ends."

  attr :marker_x, :any, default: nil, doc: "x for a dashed vertical line across every row"

  attr :ticks, :list,
    default: [],
    doc: "x values for faint vertical gridlines (hours, days) across every row"

  attr :x_format, :any,
    default: nil,
    doc: "1-arity fun formatting an x for band titles (e.g. minutes to a clock time)"

  attr :row_height, :any, default: 2, doc: "Row height in rem"

  attr :scroll_after, :any,
    default: 12,
    doc: "Rows shown before the list scrolls inside a fixed height; `nil` never scrolls"

  attr :class, :any, default: nil, doc: "Classes for the wrapper (set text-* for the marker)"
  attr :aria_label, :string, default: nil
  attr :rest, :global

  slot :row_label, doc: "Custom content over each row; receives the row map via `:let`"
  slot :band, doc: "Custom content inside each band; receives the band's map via `:let`"
  slot :empty, doc: "Shown when there are no rows or the domain is unusable"

  def chart_lanes(assigns) do
    domain = ChartScale.domain(assigns.x_domain, [])
    row_height = positive_number(assigns.row_height, 2)
    scroll_after = positive_integer(assigns.scroll_after)

    rows =
      if domain,
        do:
          assigns.rows
          |> List.wrap()
          |> Enum.with_index()
          |> Enum.map(&row(&1, domain, assigns))
          |> assign_dom_ids(),
        else: []

    assigns =
      assign(assigns,
        lane_rows: rows,
        marker: position(assigns.marker_x, domain),
        tick_positions:
          assigns.ticks
          |> List.wrap()
          |> Enum.map(&position(&1, domain))
          |> Enum.reject(&is_nil/1),
        row_height: row_height,
        max_height: scroll_after && length(rows) > scroll_after && scroll_after * row_height
      )

    ~H"""
    <div id={@id} class={["pk-chart-lanes relative w-full", @class]} {@rest}>
      <ul
        :if={@lane_rows != []}
        role="list"
        aria-label={@aria_label}
        class={["relative", @max_height && "overflow-y-auto"]}
        style={@max_height && "max-height: #{@max_height}rem; scrollbar-width: thin"}
      >
        <li
          :for={row <- @lane_rows}
          id={"#{@id}-row-#{row.dom_id}"}
          class="relative border-b border-base-content/5 last:border-b-0"
          style={"height: #{@row_height}rem"}
        >
          <%!-- Gridlines and the marker are drawn in every row, inside the same
               box as the bands: a scrollbar that narrows the list narrows them
               too, so they never drift from the bands. --%>
          <div
            :for={tick <- @tick_positions}
            class="absolute inset-y-0 border-l border-base-content/10 pointer-events-none"
            style={"left: #{tick}%"}
            aria-hidden="true"
          >
          </div>
          <div class="absolute inset-0" aria-hidden={@band == [] && "true"}>
            <div
              :for={band <- row.bands}
              class={[
                "absolute top-1 bottom-1 flex items-center overflow-hidden",
                band.point && "-translate-x-1/2",
                band.class
              ]}
              style={band.style}
              title={band.title}
              data-from={band.from}
              data-to={band.to}
            >
              <span class={["absolute inset-0 rounded-sm", band.variant_class]}></span>
              <%= if @band != [] do %>
                <span class="relative w-full h-full">{render_slot(@band, band.source)}</span>
              <% else %>
                <span
                  :if={band.label && !band.point}
                  class="relative px-1 text-[0.65rem] leading-none truncate text-base-content"
                >
                  {band.label}
                </span>
              <% end %>
            </div>
          </div>
          <div
            :if={@marker}
            class="absolute inset-y-0 border-l border-dashed border-current opacity-60 pointer-events-none"
            style={"left: #{@marker}%"}
            aria-hidden="true"
          >
          </div>
          <div class="relative flex items-center gap-2 h-full px-2 text-xs pointer-events-none">
            <%= if @row_label != [] do %>
              <span class="pointer-events-auto truncate">
                {render_slot(@row_label, row.source)}
              </span>
            <% else %>
              <span class="font-medium truncate">{row.label}</span>
              <span :if={row.note} class="opacity-60 truncate">{row.note}</span>
            <% end %>
          </div>
          <span class="sr-only">{row.summary}</span>
        </li>
      </ul>
      <div :if={@lane_rows == []}>{render_slot(@empty)}</div>
    </div>
    """
  end

  defp row({row, index}, domain, assigns) when is_map(row) do
    label = field(row, :label)
    bands = row |> field(:bands) |> List.wrap() |> Enum.flat_map(&band(&1, domain, assigns))

    %{
      index: index,
      id: field(row, :id),
      label: label,
      note: field(row, :note),
      bands: bands,
      source: row,
      summary: summary(label, bands)
    }
  end

  defp row({_row, index}, _domain, _assigns) do
    %{index: index, id: nil, label: nil, note: nil, bands: [], source: %{}, summary: ""}
  end

  # A row's DOM id follows the caller's `:id` when it has one, so reordering
  # rows does not hand one row's element to another; the position is the
  # fallback, and a repeated id gets its position appended to stay unique.
  defp assign_dom_ids(rows) do
    {rows, _seen} =
      Enum.map_reduce(rows, MapSet.new(), fn row, seen ->
        base =
          case row.id do
            nil -> "i#{row.index}"
            id -> id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
          end

        dom_id = if MapSet.member?(seen, base), do: "#{base}-#{row.index}", else: base
        {Map.put(row, :dom_id, dom_id), MapSet.put(seen, dom_id)}
      end)

    rows
  end

  defp band(band, domain, assigns) when is_map(band) do
    from = field(band, :from)
    to = field(band, :to)

    case placement(domain, from, to) do
      nil ->
        []

      {style, point?} ->
        label = field(band, :label)

        [
          %{
            style: style,
            point: point?,
            from: ChartScale.numeric(from),
            to: ChartScale.numeric(to),
            variant_class: variant_class(field(band, :variant)),
            class: field(band, :class),
            label: label,
            source: band,
            title: field(band, :title) || label || range_title(from, to, domain, assigns.x_format)
          }
        ]
    end
  end

  defp band(_band, _domain, _assigns), do: []

  # A point (`from == to`, both given) is a thin mark centred on its x;
  # anything else is the clipped span, or nothing.
  defp placement(domain, from, to) do
    with f when is_number(f) <- ChartScale.numeric(from),
         t when is_number(t) <- ChartScale.numeric(to),
         true <- f == t,
         left when is_float(left) <- position(f, domain) do
      {"left: #{left}%; width: 3px", true}
    else
      _ ->
        case ChartScale.span(domain, from, to) do
          nil -> nil
          %{left: l, width: w} -> {"left: #{round2(l)}%; width: #{round2(w)}%", false}
        end
    end
  end

  defp variant_class(variant) when is_atom(variant) and not is_nil(variant),
    do: variant_class(Atom.to_string(variant))

  defp variant_class(variant) when is_binary(variant),
    do: Map.get(@variants, variant, @variants["fill"])

  defp variant_class(_), do: @variants["fill"]

  defp range_title(from, to, {lo, hi}, format) do
    from = ChartScale.numeric(from) || lo
    to = ChartScale.numeric(to) || hi

    if from == to,
      do: format_x(from, format),
      else: "#{format_x(from, format)}–#{format_x(to, format)}"
  end

  defp format_x(x, format) when is_function(format, 1) do
    to_string(format.(x))
  rescue
    _ -> to_string(x)
  end

  defp format_x(x, _format), do: to_string(x)

  defp summary(label, bands) do
    [label | Enum.map(bands, & &1.title)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join(", ", &to_string/1)
  end

  # An x inside the domain as a percentage, else nil.
  defp position(nil, _domain), do: nil
  defp position(_x, nil), do: nil

  defp position(x, {lo, hi} = domain) do
    case ChartScale.numeric(x) do
      nil -> nil
      n when n >= lo and n <= hi -> round2(ChartScale.percent(domain, n))
      _ -> nil
    end
  end

  # Rows and bands come from callers' own data, as atom- or string-keyed maps.
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp positive_number(value, default) do
    case ChartScale.numeric(value) do
      n when is_number(n) and n > 0 -> n
      _ -> default
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp round2(value), do: Float.round(value * 1.0, 2)
end
