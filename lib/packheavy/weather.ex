defmodule Packheavy.Weather do
  @moduledoc """
  Daily forecast lookup against the Open-Meteo API. Free, keyless,
  ACCESS-G (BOM) is one of the AU model sources under the hood.

  Returns min/max °C and a WMO weather code per day. Forecast horizon
  is ~16 days — anything outside that is silently dropped (the calling
  view just doesn't render weather for those days).

  Results are cached in an ETS table created by `init_cache/0` (called
  once from the application supervisor) keyed by lat/lon rounded to
  0.1° + date, with a one-hour TTL.
  """

  require Logger

  @cache_table :packheavy_weather_cache
  @cache_ttl_ms 60 * 60 * 1000
  @forecast_horizon_days 16
  @http_recv_timeout_ms 5_000
  @api_url "https://api.open-meteo.com/v1/forecast"

  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Returns `%{day_index => %{tmin, tmax, code, label}}` for a trip. Day
  index is 1-based and aligns with `leg.day`. Empty map when the trip
  has no `start_date`, no GPX legs, or the entire range falls outside
  the forecast horizon.
  """
  def trip_forecast(trip) do
    with %Date{} = start_d <- Map.get(trip, :start_date) || nil,
         legs when is_list(legs) and legs != [] <- Map.get(trip, :trip_legs) || [],
         {lat, lon} <- first_track_coord(legs),
         n when is_integer(n) and n > 0 <- trip_day_count(trip, legs) do
      today = Date.utc_today()
      horizon_end = Date.add(today, @forecast_horizon_days)
      natural_end = Date.add(start_d, n - 1)

      fetch_start = if Date.compare(start_d, today) == :lt, do: today, else: start_d
      fetch_end = if Date.compare(natural_end, horizon_end) == :gt, do: horizon_end, else: natural_end

      cond do
        Date.compare(fetch_start, fetch_end) == :gt ->
          %{}

        true ->
          case fetch_or_cached(lat, lon, fetch_start, fetch_end) do
            {:ok, by_date} ->
              for {date, val} <- by_date,
                  day = Date.diff(date, start_d) + 1,
                  day >= 1 and day <= n,
                  into: %{},
                  do: {day, val}

            :error ->
              %{}
          end
      end
    else
      _ -> %{}
    end
  end

  defp trip_day_count(%{start_date: %Date{} = sd, end_date: %Date{} = ed}, legs) do
    leg_max = legs |> Enum.map(&Map.get(&1, :day, 1)) |> Enum.max(fn -> 1 end)
    max(Date.diff(ed, sd) + 1, leg_max)
  end

  defp trip_day_count(%{start_date: %Date{}}, legs) do
    legs |> Enum.map(&Map.get(&1, :day, 1)) |> Enum.max(fn -> 1 end)
  end

  defp trip_day_count(_, _), do: 0

  defp first_track_coord(legs) do
    leg = legs |> Enum.sort_by(&Map.get(&1, :position, 0)) |> List.first()

    case leg && Map.get(leg, :track) do
      [%{} = pt | _] ->
        lat = Map.get(pt, :lat) || Map.get(pt, "lat")
        lon = Map.get(pt, :lon) || Map.get(pt, "lon")
        if is_number(lat) and is_number(lon), do: {lat, lon}, else: nil

      _ ->
        nil
    end
  end

  defp fetch_or_cached(lat, lon, %Date{} = start_d, %Date{} = end_d) do
    cl = Float.round(lat * 1.0, 1)
    co = Float.round(lon * 1.0, 1)
    needed = Date.range(start_d, end_d) |> Enum.to_list()
    now = System.monotonic_time(:millisecond)

    cached =
      Enum.reduce(needed, %{}, fn date, acc ->
        case :ets.lookup(@cache_table, {cl, co, date}) do
          [{_, val, ts}] when now - ts < @cache_ttl_ms -> Map.put(acc, date, val)
          _ -> acc
        end
      end)

    if map_size(cached) == length(needed) do
      {:ok, cached}
    else
      case http_fetch(lat, lon, start_d, end_d) do
        {:ok, fetched} ->
          Enum.each(fetched, fn {d, v} ->
            :ets.insert(@cache_table, {{cl, co, d}, v, now})
          end)

          {:ok, fetched}

        :error ->
          if map_size(cached) > 0, do: {:ok, cached}, else: :error
      end
    end
  end

  defp http_fetch(lat, lon, %Date{} = start_d, %Date{} = end_d) do
    params = [
      latitude: Float.round(lat * 1.0, 4),
      longitude: Float.round(lon * 1.0, 4),
      daily: "temperature_2m_max,temperature_2m_min,weather_code",
      timezone: "auto",
      start_date: Date.to_iso8601(start_d),
      end_date: Date.to_iso8601(end_d)
    ]

    case Req.get(@api_url, params: params, receive_timeout: @http_recv_timeout_ms) do
      {:ok, %Req.Response{status: 200, body: %{"daily" => %{} = daily}}} ->
        {:ok, parse_daily(daily)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Open-Meteo non-200: status=#{status} body=#{inspect(body)}")
        :error

      {:error, reason} ->
        Logger.warning("Open-Meteo request failed: #{inspect(reason)}")
        :error
    end
  end

  defp parse_daily(daily) do
    times = Map.get(daily, "time", [])
    tmaxs = Map.get(daily, "temperature_2m_max", [])
    tmins = Map.get(daily, "temperature_2m_min", [])
    codes = Map.get(daily, "weather_code", [])

    [times, tmins, tmaxs, codes]
    |> Enum.zip()
    |> Enum.reduce(%{}, fn {t, mn, mx, c}, acc ->
      case Date.from_iso8601(t || "") do
        {:ok, date} ->
          Map.put(acc, date, %{
            tmin: round_temp(mn),
            tmax: round_temp(mx),
            code: c,
            label: wmo_label(c)
          })

        _ ->
          acc
      end
    end)
  end

  defp round_temp(v) when is_number(v), do: Float.round(v * 1.0, 1)
  defp round_temp(_), do: nil

  @doc """
  WMO weather-interpretation code → short human label.
  Reference: https://open-meteo.com/en/docs (WMO 4677 codes).
  """
  def wmo_label(code) do
    case code do
      0 -> "clear"
      1 -> "mainly clear"
      2 -> "partly cloudy"
      3 -> "overcast"
      45 -> "fog"
      48 -> "freezing fog"
      51 -> "light drizzle"
      53 -> "drizzle"
      55 -> "heavy drizzle"
      56 -> "freezing drizzle"
      57 -> "freezing drizzle"
      61 -> "light rain"
      63 -> "rain"
      65 -> "heavy rain"
      66 -> "freezing rain"
      67 -> "freezing rain"
      71 -> "light snow"
      73 -> "snow"
      75 -> "heavy snow"
      77 -> "snow grains"
      80 -> "rain showers"
      81 -> "rain showers"
      82 -> "heavy showers"
      85 -> "snow showers"
      86 -> "snow showers"
      95 -> "thunderstorm"
      96 -> "thunderstorm w/ hail"
      99 -> "thunderstorm w/ hail"
      _ -> nil
    end
  end

  @doc """
  Pretty-print a forecast map for the day-header line:
  `"6.2°/14.1° · partly cloudy"`. Returns `nil` for nil input.
  """
  def format_forecast(nil), do: nil

  def format_forecast(%{tmin: mn, tmax: mx} = w) when is_number(mn) and is_number(mx) do
    label = Map.get(w, :label)
    base = "#{format_temp(mn)}/#{format_temp(mx)}"
    if label, do: "#{base} · #{label}", else: base
  end

  def format_forecast(_), do: nil

  defp format_temp(v) when is_number(v) do
    rounded = Float.round(v * 1.0, 1)
    "#{:erlang.float_to_binary(rounded, decimals: 1)}°"
  end
end
