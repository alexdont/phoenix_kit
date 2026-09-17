defmodule PhoenixKitWeb.Components.Core.ChartScale do
  @moduledoc """
  The horizontal scale `PhoenixKitWeb.Components.Core.Chart.line_chart/1`
  draws with, for lining your own HTML up with a chart.

  A line chart stretches its SVG across its wrapper, so an x value always
  lands at the same **percentage** of the wrapper's width, whatever size the
  page gives it. Anything positioned with `left: <percent>%` inside a box of
  the same width — a band, a label, a "now" line — sits exactly over the
  chart. `PhoenixKitWeb.Components.Core.ChartLanes.chart_lanes/1` is built on
  this module; use it directly for overlays of your own.

      domain = ChartScale.domain(@x_domain, Enum.map(@points, &elem(&1, 0)))
      left = ChartScale.percent(domain, @now_minute)
      # <div class="absolute inset-y-0" style={"left: \#{left}%"}></div>

  Pass the chart the same `x_domain` you give the overlay. Without one, the
  chart fits its own data, and the overlay only matches if it computes the
  domain from the same x values.

  Like the charts, this module takes plain numbers (and `Decimal`s). Map
  times, prices or dates to numbers first.
  """

  @typedoc "An x range, `{low, high}`, `low <= high`."
  @type domain :: {number(), number()}

  @typedoc "Where a range sits across the chart, in percent of its width."
  @type span :: %{left: float(), width: float()}

  @doc """
  A chart value as a number: integers and floats as they are, a `Decimal`
  as a float, anything else `nil`.

      iex> PhoenixKitWeb.Components.Core.ChartScale.numeric(Decimal.new("1.5"))
      1.5

      iex> PhoenixKitWeb.Components.Core.ChartScale.numeric("12")
      nil
  """
  @spec numeric(term()) :: number() | nil
  def numeric(value) when is_integer(value) or is_float(value), do: value

  def numeric(%Decimal{} = value) do
    Decimal.to_float(value)
  rescue
    _ -> nil
  end

  def numeric(_), do: nil

  @doc """
  The x domain `line_chart/1` uses: the explicit `{low, high}` when both
  bounds are numbers (a reversed pair is swapped), otherwise the lowest and
  highest of `xs`. `nil` when neither gives a number.

  An unusable explicit bound falls back to the data, never to a constant:
  a `{0, 1}` fallback would scale every real range off the chart.

      iex> PhoenixKitWeb.Components.Core.ChartScale.domain({1440, 0}, [])
      {0, 1440}

      iex> PhoenixKitWeb.Components.Core.ChartScale.domain(nil, [30, 10, 20])
      {10, 30}

      iex> PhoenixKitWeb.Components.Core.ChartScale.domain({nil, 5}, [])
      nil
  """
  @spec domain(term(), [term()]) :: domain() | nil
  def domain(explicit, xs) when is_list(xs) do
    explicit_domain(explicit) || data_domain(xs)
  end

  defp explicit_domain({a, b}) do
    case {numeric(a), numeric(b)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {lo, hi} when lo > hi -> {hi, lo}
      {lo, hi} -> {lo, hi}
    end
  end

  defp explicit_domain(_), do: nil

  defp data_domain(xs) do
    case xs |> Enum.map(&numeric/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      numbers -> Enum.min_max(numbers)
    end
  end

  @doc """
  Where `x` sits across the domain, as a fraction: `0.0` at the low edge,
  `1.0` at the high edge. Not clamped — a value outside the domain lands
  outside `0..1`, as it does on the chart. A domain with no width puts every
  value at the centre (`0.5`).

      iex> PhoenixKitWeb.Components.Core.ChartScale.fraction({0, 1440}, 360)
      0.25
  """
  @spec fraction(domain(), number()) :: float()
  def fraction({lo, hi}, x) when hi > lo, do: (x - lo) / (hi - lo)
  def fraction({_lo, _hi}, _x), do: 0.5

  @doc """
  `fraction/2` as a percentage of the chart's width, for `left: …%`.

      iex> PhoenixKitWeb.Components.Core.ChartScale.percent({0, 1440}, 720)
      50.0
  """
  @spec percent(domain(), number()) :: float()
  def percent(domain, x), do: fraction(domain, x) * 100

  @doc """
  The part of the chart the range `from..to` covers, clipped to the domain:
  `%{left: percent, width: percent}`. A `nil` bound is open and runs to the
  domain's edge. `nil` when nothing of the range is left — it lies outside
  the domain, is empty, runs backwards, or a bound is not a number.

      iex> PhoenixKitWeb.Components.Core.ChartScale.span({0, 100}, 25, 50)
      %{left: 25.0, width: 25.0}

      iex> PhoenixKitWeb.Components.Core.ChartScale.span({0, 100}, 90, nil)
      %{left: 90.0, width: 10.0}

      iex> PhoenixKitWeb.Components.Core.ChartScale.span({0, 100}, 120, 150)
      nil
  """
  @spec span(domain(), term(), term()) :: span() | nil
  def span({lo, hi} = domain, from, to) when hi > lo do
    with {:ok, from} <- bound(from, lo),
         {:ok, to} <- bound(to, hi),
         true <- from < to,
         left = max(from, lo),
         right = min(to, hi),
         true <- left < right do
      start = percent(domain, left)
      %{left: start, width: percent(domain, right) - start}
    else
      _ -> nil
    end
  end

  def span(_domain, _from, _to), do: nil

  defp bound(nil, edge), do: {:ok, edge}

  defp bound(value, _edge) do
    case numeric(value) do
      nil -> :error
      number -> {:ok, number}
    end
  end
end
