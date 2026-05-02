defmodule Packheavy.Trips.Helpers do
  @moduledoc """
  Misc helpers for the trip subsystem. Currently just GPX-track
  canonicalisation; lives here rather than on `Packheavy.Gpx` so
  callers can reach it without depending on the parser module.
  """

  @earth_radius_m 6_371_000.0

  @doc """
  Build the indexed track that both the map polyline and the chart
  consume. Cumulative distance is computed over every point (including
  ones missing `:ele`) so chart x-coords stay aligned with map marker
  positions.

  Returns `[%{lat: float, lon: float, ele: float | nil, d: float}]`.
  """
  def canonical_track(points) do
    {acc, _, _} =
      Enum.reduce(points, {[], nil, 0.0}, fn pt, {acc, prev, total} ->
        d =
          case prev do
            nil -> 0.0
            _ -> total + haversine(prev, pt)
          end

        entry = %{lat: pt.lat, lon: pt.lon, ele: pt.ele, d: d}
        {[entry | acc], pt, d}
      end)

    Enum.reverse(acc)
  end

  defp haversine(%{lat: lat1, lon: lon1}, %{lat: lat2, lon: lon2}) do
    rlat1 = :math.pi() * lat1 / 180
    rlat2 = :math.pi() * lat2 / 180
    dlat = :math.pi() * (lat2 - lat1) / 180
    dlon = :math.pi() * (lon2 - lon1) / 180
    a = :math.sin(dlat / 2) ** 2 + :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlon / 2) ** 2
    @earth_radius_m * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  @doc """
  Sum of the trip's legs' `:distance_m`, returned in **kilometres** as
  a float. Returns `nil` if the trip has no legs (so callers can treat
  "no GPX uploaded yet" distinct from "0 km hike"). Requires `trip_legs`
  to be loaded.
  """
  def trip_distance_km(%{trip_legs: legs}) when is_list(legs) and legs != [] do
    legs |> Enum.map(& &1.distance_m) |> Enum.sum() |> Kernel./(1000.0)
  end

  def trip_distance_km(_), do: nil

  @doc """
  Sum of the trip's legs' `:elevation_gain_m`, returned as a float.
  `nil` if no legs. Requires `trip_legs` to be loaded.
  """
  def trip_elevation_gain_m(%{trip_legs: legs}) when is_list(legs) and legs != [] do
    legs |> Enum.map(& &1.elevation_gain_m) |> Enum.sum() |> Kernel.*(1.0)
  end

  def trip_elevation_gain_m(_), do: nil

  @doc """
  Returns the leader hiker's `weight_kg` (Decimal), or `nil` if no
  leader is present, the leader has no weight set, or `trip_hikers`
  isn't loaded.
  """
  def leader_weight_kg(%{trip_hikers: hikers}) when is_list(hikers) do
    case Enum.find(hikers, &(&1.role == :leader)) do
      %{weight_kg: %Decimal{} = w} -> w
      _ -> nil
    end
  end

  def leader_weight_kg(_), do: nil

  # ---- Per-leg pace / time / calorie estimates --------------------------
  #
  # Time = Naismith with load: distance/pace + elevation/600. Calories
  # use the Pandolf load-carriage equation (1977), which gives the
  # metabolic rate in watts as a function of body weight, load, walking
  # speed, grade, and a terrain factor. We hardcode η=1.2 for trail
  # walking (light brush / well-formed dirt) — could be exposed per leg
  # later for sand/snow/bog if it ever matters. The MET × time formula
  # we used previously over-reported by ~3× because hiking-MET tables
  # assume a 5 km/h pace, while our Naismith-derived pace on real
  # alpine trips ends up closer to 2.5 km/h.

  # 1 W·h = 3600 J ; 1 kcal = 4184 J. So 1 W sustained for an hour is
  # 3600/4184 ≈ 0.8604 kcal.
  @watts_to_kcal_per_h 0.8604
  # Pandolf terrain factor for trail walking (light brush / well-formed
  # dirt). Pavement is 1.0, loose sand 2.1, soft snow ~1.6, swamp ~1.8.
  @pandolf_eta 1.2

  @doc "Estimated walking time for a leg in hours. Returns nil if pace is missing or zero."
  def leg_time_h(%{distance_m: d_m, elevation_gain_m: e_m, pace_kmh: pace})
      when is_number(d_m) and is_number(e_m) and is_number(pace) and pace > 0 do
    d_km = d_m / 1000.0
    d_km / pace + e_m / 600.0
  end

  def leg_time_h(_), do: nil

  @doc "Average grade percent for a leg. Returns 0.0 if distance is zero."
  def leg_grade_pct(%{distance_m: d_m, elevation_gain_m: e_m})
      when is_number(d_m) and is_number(e_m) and d_m > 0 do
    e_m / d_m * 100.0
  end

  def leg_grade_pct(_), do: 0.0

  @doc """
  Estimated calories burned for a single leg.

  `loads` is `%{full_kg: float, sidequest_kg: float}` — the helper
  picks the right one based on `leg.sidequest`. Returns `nil` if pace
  or weight inputs are missing.
  """
  def leg_calories(%{sidequest: sq?} = leg, leader_kg, %{full_kg: full, sidequest_kg: sq})
      when is_number(full) and is_number(sq) and not is_nil(leader_kg) do
    load_kg = if sq?, do: sq, else: full
    leg_calories_with_load(leg, leader_kg, load_kg)
  end

  def leg_calories(_, _, _), do: nil

  defp leg_calories_with_load(%{distance_m: d_m} = leg, leader_kg, load_kg)
       when is_number(d_m) and d_m > 0 do
    with t when is_number(t) and t > 0 <- leg_time_h(leg) do
      w = decimal_to_float(leader_kg)
      l = load_kg * 1.0
      v_mps = d_m / (t * 3600.0)
      g_pct = leg_grade_pct(leg)

      m_watts =
        1.5 * w +
          2.0 * (w + l) * :math.pow(l / w, 2) +
          @pandolf_eta * (w + l) *
            (1.5 * :math.pow(v_mps, 2) + 0.35 * v_mps * g_pct)

      round(m_watts * t * @watts_to_kcal_per_h)
    else
      _ -> nil
    end
  end

  defp leg_calories_with_load(_, _, _), do: nil

  @doc "Sum of `leg_time_h` across all legs. nil if no legs."
  def trip_time_h(%{trip_legs: legs}) when is_list(legs) and legs != [] do
    Enum.reduce(legs, 0.0, fn leg, acc -> acc + (leg_time_h(leg) || 0.0) end)
  end

  def trip_time_h(_), do: nil

  @doc "Sum of `leg_calories` across all legs. nil if no legs or inputs missing."
  def trip_calories(%{trip_legs: legs}, leader_kg, %{full_kg: _, sidequest_kg: _} = loads)
      when is_list(legs) and legs != [] and not is_nil(leader_kg) do
    legs
    |> Enum.map(&leg_calories(&1, leader_kg, loads))
    |> case do
      list ->
        if Enum.any?(list, &is_nil/1), do: nil, else: Enum.sum(list)
    end
  end

  def trip_calories(_, _, _), do: nil

  # Resting/basal energy expenditure rate. Standard adult BMR is
  # ~24 kcal/kg/day = 1 kcal/kg/h. Rough but the right order of
  # magnitude — what matters for food planning is total daily intake.
  @bmr_kcal_per_kg_h 1.0

  @doc """
  Whole-trip duration in hours, derived from start_date/end_date
  (inclusive — May 5 → May 11 is 7 days = 168 h). Returns nil if
  either date is missing.
  """
  def trip_duration_h(%{start_date: %Date{} = s, end_date: %Date{} = e}) do
    days = Date.diff(e, s) + 1
    if days > 0, do: days * 24.0, else: nil
  end

  def trip_duration_h(_), do: nil

  @doc """
  Resting calorie burn for the non-walking portion of the trip
  (sleep, camp, eating). Uses BMR × leader weight × (trip_h - walking_h).
  Returns nil if leader weight or trip duration is missing.
  """
  def trip_resting_calories(_, nil), do: nil

  def trip_resting_calories(trip, leader_kg) do
    case trip_duration_h(trip) do
      dur when is_number(dur) ->
        walk = trip_time_h(trip) || 0.0
        rest_h = max(dur - walk, 0.0)
        round(decimal_to_float(leader_kg) * @bmr_kcal_per_kg_h * rest_h)

      _ ->
        nil
    end
  end

  @doc """
  Pack loads in kg based on per-item `carry_mode`. Returns
  `%{full_kg, sidequest_kg, by_carry: %{worn, day_pack, main_pack}}`.

  - `full_kg` — every item's weight + every Water item's capacity.
  - `sidequest_kg` — only items with `carry_mode in [:worn, :day_pack]`,
    and water capacity only from items with `carry_mode == :day_pack`.

  `trip_items` must be loaded with `item: [:weight_g, :category_data]`.
  """
  def pack_loads(%{trip_items: trip_items}) when is_list(trip_items) do
    by_carry =
      Enum.reduce(trip_items, %{worn: 0, day_pack: 0, main_pack: 0}, fn ti, acc ->
        weight = (ti.item && ti.item.weight_g) || 0
        qty = ti.qty || 1
        mode = ti.carry_mode || :main_pack
        Map.update!(acc, mode, &(&1 + weight * qty))
      end)

    water_by_carry =
      Enum.reduce(trip_items, %{worn: 0, day_pack: 0, main_pack: 0}, fn ti, acc ->
        case unwrap(ti.item && ti.item.category_data) do
          %{capacity_ml: ml} when is_integer(ml) and ml > 0 ->
            qty = ti.qty || 1
            mode = ti.carry_mode || :main_pack

            if water_container?(ti.item.category_data) do
              Map.update!(acc, mode, &(&1 + ml * qty))
            else
              acc
            end

          _ ->
            acc
        end
      end)

    full_g = by_carry.worn + by_carry.day_pack + by_carry.main_pack
    full_water_g = water_by_carry.worn + water_by_carry.day_pack + water_by_carry.main_pack

    sidequest_g = by_carry.worn + by_carry.day_pack
    sidequest_water_g = water_by_carry.day_pack

    %{
      full_kg: (full_g + full_water_g) / 1000.0,
      sidequest_kg: (sidequest_g + sidequest_water_g) / 1000.0,
      by_carry: by_carry,
      water_by_carry: water_by_carry
    }
  end

  def pack_loads(_), do: %{full_kg: 0.0, sidequest_kg: 0.0, by_carry: %{worn: 0, day_pack: 0, main_pack: 0}, water_by_carry: %{worn: 0, day_pack: 0, main_pack: 0}}

  defp unwrap(%Ash.Union{value: v}), do: v
  defp unwrap(other), do: other

  defp water_container?(category_data) do
    case unwrap(category_data) do
      %Packheavy.Inventory.Item.Water{} -> true
      _ -> false
    end
  end

  @doc ~S"""
  Format a duration in hours as `"5h 20m"`. Rounds to the nearest
  minute. Returns `""` for nil.
  """
  def format_hours(nil), do: ""

  def format_hours(h) when is_number(h) do
    total_minutes = round(h * 60)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)
    "#{hours}h #{minutes}m"
  end

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n * 1.0
end
