defmodule Packheavy.Gpx do
  @moduledoc """
  Tiny GPX parser + summary stats. Pulls `<trkpt lat="..." lon="...">`
  elements (with optional `<ele>`) out of the document and computes
  total distance via Haversine and elevation gain by summing positive
  deltas with a small smoothing threshold to discount GPS jitter.

  Tested against Komoot and Garmin Connect exports. Doesn't try to be
  a full GPX implementation — no waypoints, routes, extensions.
  """

  @earth_radius_m 6_371_000.0

  @type point :: %{lat: float(), lon: float(), ele: float() | nil}
  @type stats :: %{distance_m: float(), elevation_gain_m: float(), point_count: non_neg_integer()}

  @spec parse(binary()) :: {:ok, %{points: [point()], stats: stats()}} | {:error, atom()}
  def parse(binary) when is_binary(binary) do
    points = extract_trkpts(binary)

    if points == [] do
      {:error, :no_trackpoints}
    else
      {:ok,
       %{
         points: points,
         stats: %{
           distance_m: distance_m(points),
           elevation_gain_m: elevation_gain_m(points),
           point_count: length(points)
         }
       }}
    end
  end

  defp extract_trkpts(binary) do
    Regex.scan(~r/<trkpt\s+([^>]*?)(?:\/>|>(.*?)<\/trkpt>)/s, binary, capture: :all_but_first)
    |> Enum.flat_map(fn
      [attrs, body] -> wrap_point(parse_attrs(attrs), parse_ele(body))
      [attrs] -> wrap_point(parse_attrs(attrs), nil)
    end)
  end

  defp wrap_point(%{lat: lat, lon: lon}, ele) when is_float(lat) and is_float(lon),
    do: [%{lat: lat, lon: lon, ele: ele}]

  defp wrap_point(_, _), do: []

  defp parse_attrs(attrs) do
    %{
      lat: parse_float_attr(attrs, "lat"),
      lon: parse_float_attr(attrs, "lon")
    }
  end

  defp parse_float_attr(attrs, name) do
    case Regex.run(~r/#{name}\s*=\s*"(-?\d+(?:\.\d+)?)"/, attrs, capture: :all_but_first) do
      [v] -> to_float(v)
      _ -> nil
    end
  end

  defp parse_ele(body) do
    case Regex.run(~r/<ele>\s*(-?\d+(?:\.\d+)?)\s*<\/ele>/, body, capture: :all_but_first) do
      [v] -> to_float(v)
      _ -> nil
    end
  end

  defp to_float(s) do
    s = if String.contains?(s, "."), do: s, else: s <> ".0"
    String.to_float(s)
  end

  @doc "Total distance in metres, summed over consecutive trackpoints via Haversine."
  @spec distance_m([point()]) :: float()
  def distance_m(points) when length(points) < 2, do: 0.0

  def distance_m(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc -> acc + haversine(a, b) end)
  end

  defp haversine(%{lat: lat1, lon: lon1}, %{lat: lat2, lon: lon2}) do
    rlat1 = deg2rad(lat1)
    rlat2 = deg2rad(lat2)
    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(rlat1) * :math.cos(rlat2) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_m * c
  end

  defp deg2rad(deg), do: :math.pi() * deg / 180.0

  @doc """
  Cumulative positive elevation change. Komoot/Strava exports are
  already DEM-smoothed, so we just sum positive deltas — extra
  smoothing here would silently under-report against their UI numbers.
  """
  @spec elevation_gain_m([point()]) :: float()
  def elevation_gain_m(points) do
    points
    |> Enum.map(& &1.ele)
    |> Enum.reject(&is_nil/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc ->
      diff = b - a
      if diff > 0, do: acc + diff, else: acc
    end)
  end
end
