defmodule PackheavyWeb.PublicTripLive do
  @moduledoc """
  Read-only public view of a trip's gear list. Reached via
  `/share/trip/:token` where `:token` is the opaque share token set on
  the trip via `Trips.enable_trip_sharing!/1`.

  Authorization: handled by the `:read_by_share_token` action's policy
  bypass on `Packheavy.Trips.Trip`. The action filter requires a
  non-nil share_token AND a match — there is no way to enumerate trips
  through this route. We never pass `actor:` here; the policy lets the
  action through without one.

  Reuses public helpers from PackheavyWeb.TripLive.Show
  (`weight_breakdown`, `food_calories`, `pack_capacity`,
  `format_capacity`, `trip_days`) so totals are computed identically
  to the planning view.
  """

  use PackheavyWeb, :live_view

  alias Packheavy.Trips
  alias PackheavyWeb.TripLive.Show, as: TripShow

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    # Two-step: the policy bypass on `:read_by_share_token` confirms
    # the share token matches a trip; once that's authorized we load
    # the children with `authorize?: false`. The TripItem / Item
    # policies are actor-scoped (no anonymous read), but this anonymous
    # request *was* authorized at the entry point — so re-running their
    # checks here is wrong, not safer. Same idiom as Trip.add_kit's
    # internal `Ash.create!(... authorize?: false)` after the outer
    # action passes.
    case Trips.read_trip_by_share_token(token) do
      {:ok, %{} = trip} ->
        trip =
          Ash.load!(
            trip,
            [
              :validation_report,
              :trip_legs,
              :trip_hikers,
              trip_items: [:item]
            ],
            authorize?: false
          )

        {:ok,
         socket
         |> assign(:page_title, "#{trip.name} · packheavy")
         |> assign(:trip, trip)
         |> assign(:og, build_og(trip, token))}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Not found · packheavy")
         |> assign(:trip, nil)}
    end
  end

  # Title + description for OG / Twitter card unfurls. Description is
  # a compact one-liner: "{n} items · {weight}g[ · {kcal} kcal][ ·
  # {start} → {end}]". Kept short so Slack/Discord show it inline
  # without truncation.
  defp build_og(trip, token) do
    items = trip.trip_items
    n_items = length(items)

    total_g =
      items
      |> Enum.map(fn ti -> (ti.item.weight_g || 0) * ti.qty end)
      |> Enum.sum()

    totals = (trip.validation_report || %{}) |> Map.get(:totals, %{})
    calories = Map.get(totals, :calories, 0)

    item_word = if n_items == 1, do: "item", else: "items"

    date_part =
      cond do
        trip.start_date && trip.end_date ->
          "#{Calendar.strftime(trip.start_date, "%b %-d")} → #{Calendar.strftime(trip.end_date, "%b %-d")}"

        trip.start_date ->
          Calendar.strftime(trip.start_date, "%b %-d, %Y")

        true ->
          nil
      end

    parts =
      [
        "#{n_items} #{item_word}",
        "#{total_g}g",
        if(calories > 0, do: "#{calories} kcal"),
        date_part
      ]
      |> Enum.reject(&is_nil/1)

    %{
      title: trip.name,
      description: Enum.join(parts, " · "),
      url: PackheavyWeb.Endpoint.url() <> "/share/trip/#{token}"
    }
  end

  @impl true
  def handle_event("fly-to-leg", %{"id" => id}, socket) do
    {:noreply, push_event(socket, "gpx:fly", %{leg_id: id})}
  end

  @impl true
  def render(%{trip: nil} = assigns) do
    ~H"""
    <main class="min-h-screen p-8 flex items-center justify-center">
      <div class="max-w-md text-center space-y-2">
        <h1 class="text-2xl font-bold">Not found</h1>
        <p class="opacity-70 text-sm">
          This share link is invalid or has been revoked.
        </p>
      </div>
    </main>
    """
  end

  def render(assigns) do
    grouped =
      assigns.trip.trip_items
      |> Enum.sort_by(fn ti ->
        item = ti.item
        String.downcase("#{item && item.brand || ""} #{item && item.title}")
      end)
      |> Enum.group_by(fn ti ->
        case ti.item && ti.item.category_data do
          %Ash.Union{type: t} -> t
          _ -> :other
        end
      end)

    visible_categories =
      Enum.filter(category_order(), fn {cat, _} -> Map.has_key?(grouped, cat) end)

    section_weight = fn cat ->
      grouped
      |> Map.get(cat, [])
      |> Enum.map(fn ti -> (ti.item.weight_g || 0) * ti.qty end)
      |> Enum.sum()
    end

    section_capacity = fn cat ->
      total =
        grouped
        |> Map.get(cat, [])
        |> Enum.map(fn ti ->
          case TripShow.pack_capacity(ti) do
            v when is_number(v) -> v * ti.qty
            _ -> 0
          end
        end)
        |> Enum.sum()

      if total > 0, do: total, else: nil
    end

    section_calories = fn cat ->
      total =
        grouped
        |> Map.get(cat, [])
        |> Enum.map(fn ti ->
          case TripShow.food_calories(ti) do
            c when is_integer(c) -> c * ti.qty
            _ -> 0
          end
        end)
        |> Enum.sum()

      if total > 0, do: total, else: nil
    end

    legs_with_color =
      assigns.trip.trip_legs
      |> Enum.with_index()
      |> Enum.map(fn {leg, idx} ->
        Map.put(leg, :color, Enum.at(leg_palette(), rem(idx, length(leg_palette()))))
      end)

    legs_payload_json =
      legs_with_color
      |> Enum.map(fn leg ->
        %{id: leg.id, name: leg.name, color: leg.color, track: leg.track}
      end)
      |> Jason.encode!()

    legs_by_day_map =
      legs_with_color
      |> Enum.group_by(& &1.day)
      |> Map.new(fn {day, legs} -> {day, Enum.sort_by(legs, & &1.position)} end)

    leg_max_day = legs_by_day_map |> Map.keys() |> Enum.max(fn -> 0 end)
    date_days = TripShow.trip_days(assigns.trip) || 0
    days_to_show = max(date_days, leg_max_day) |> max(0)

    legs_by_day =
      Enum.map(1..max(days_to_show, 1), fn day ->
        {day, Map.get(legs_by_day_map, day, [])}
      end)

    has_legs? = legs_with_color != []

    leader_kg = Packheavy.Trips.Helpers.leader_weight_kg(assigns.trip)
    loads = Packheavy.Trips.Helpers.pack_loads(assigns.trip)

    assigns =
      assigns
      |> assign(grouped: grouped)
      |> assign(visible_categories: visible_categories)
      |> assign(section_weight: section_weight)
      |> assign(section_capacity: section_capacity)
      |> assign(section_calories: section_calories)
      |> assign(legs_with_color: legs_with_color)
      |> assign(legs_by_day: legs_by_day)
      |> assign(legs_payload_json: legs_payload_json)
      |> assign(has_legs?: has_legs?)
      |> assign(leader_kg: leader_kg)
      |> assign(loads: loads)

    ~H"""
    <main class="min-h-screen px-4 py-6 sm:px-6 lg:px-8">
      <div class="max-w-7xl mx-auto space-y-4">
        <header class="border-b border-base-300 pb-3">
          <h1 class="text-2xl font-bold">{@trip.name}</h1>
          <div :if={@trip.start_date || @trip.end_date} class="text-sm opacity-70 mt-1">
            <span :if={@trip.start_date}>{Calendar.strftime(@trip.start_date, "%b %-d, %Y")}</span>
            <span :if={@trip.start_date && @trip.end_date} class="mx-1">→</span>
            <span :if={@trip.end_date}>{Calendar.strftime(@trip.end_date, "%b %-d, %Y")}</span>
          </div>
          <p class="text-xs opacity-50 mt-2">Read-only · shared via packheavy</p>
        </header>

        <% report = @trip.validation_report || %{totals: %{}} %>
        <% totals = report.totals || %{} %>
        <% calories = Map.get(totals, :calories, 0) %>
        <% active = Map.get(totals, :calories_burned_active) %>
        <% resting = Map.get(totals, :calories_burned_resting) %>
        <% time_h = Map.get(totals, :time_h) %>
        <% total_distance_m = @legs_with_color |> Enum.map(& &1.distance_m) |> Enum.sum() %>
        <% total_gain_m = @legs_with_color |> Enum.map(& &1.elevation_gain_m) |> Enum.sum() %>
        <% pack_kg = @loads.full_kg %>

        <!-- Top-of-page summary: route stats + gear stats side-by-side. -->
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-7 gap-2">
          <div :if={@has_legs?} class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Distance</div>
            <div class="text-lg font-semibold tabular-nums">
              {:erlang.float_to_binary(total_distance_m / 1000, decimals: 2)} km
            </div>
          </div>
          <div :if={@has_legs?} class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Elevation gain</div>
            <div class="text-lg font-semibold tabular-nums">+{round(total_gain_m)} m</div>
          </div>
          <div :if={@has_legs? && time_h} class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Walking time</div>
            <div class="text-lg font-semibold tabular-nums">{Packheavy.Trips.Helpers.format_hours(time_h)}</div>
          </div>
          <div class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Pack weight</div>
            <div class="text-lg font-semibold tabular-nums">{:erlang.float_to_binary(pack_kg, decimals: 2)} kg</div>
            <div :if={@loads.sidequest_kg > 0} class="text-xs opacity-50 tabular-nums" title="Worn + day-pack only">
              sidequest: {:erlang.float_to_binary(@loads.sidequest_kg, decimals: 2)} kg
            </div>
          </div>
          <div class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Calories carried</div>
            <div class="text-lg font-semibold tabular-nums">{calories} kcal</div>
          </div>
          <div :if={active} class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Burn (active)</div>
            <div class="text-lg font-semibold tabular-nums">{active} kcal</div>
            <div class="text-xs opacity-50">while walking</div>
          </div>
          <div :if={resting} class="card bg-base-200 p-3">
            <div class="text-xs opacity-70">Burn (resting)</div>
            <div class="text-lg font-semibold tabular-nums">{resting} kcal</div>
            <div class="text-xs opacity-50">camp/sleep BMR</div>
          </div>
        </div>

        <!-- Route — collapsible. Open by default if there are legs. -->
        <details :if={@has_legs?} class="card bg-base-200" open>
          <summary class="cursor-pointer p-4 font-semibold">Route</summary>
          <div class="p-4 pt-0 space-y-4">
            <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_360px] gap-4">
              <div
                id="public-route-map"
                phx-hook="RouteMap"
                phx-update="ignore"
                data-legs={@legs_payload_json}
                class="w-full h-[500px] lg:h-[640px] rounded order-first"
              >
              </div>
              <div class="space-y-4 max-h-[640px] overflow-y-auto">
                <div :for={{day, day_legs} <- @legs_by_day}>
                  <div class="flex items-baseline gap-3 flex-wrap mb-1">
                    <h3 class="text-sm font-bold uppercase tracking-wide opacity-80">
                      Day {day}<span :if={date = day_date(@trip, day)} class="opacity-60 font-normal normal-case ml-2">{date}</span>
                    </h3>
                    <span :if={day_legs != []} class="text-xs opacity-60 tabular-nums">
                      {day_summary(day_legs)}
                    </span>
                    <span :if={day_legs == []} class="text-xs opacity-50 italic">no legs</span>
                  </div>

                  <div :for={leg <- day_legs} class="card bg-base-100 p-3 space-y-2 mb-2">
                    <div class="flex items-start gap-2">
                      <span class="inline-block w-3 h-3 rounded-sm shrink-0 mt-1.5" style={"background-color: #{leg.color}"}></span>
                      <div class="flex-1 min-w-0">
                        <div class="font-semibold break-words">
                          {leg.name}
                          <span :if={leg.sidequest} class="badge badge-xs badge-info ml-1 align-middle">sidequest</span>
                        </div>
                        <div class="text-xs opacity-70 tabular-nums mt-0.5">
                          {:erlang.float_to_binary(leg.distance_m / 1000, decimals: 2)} km · +{round(leg.elevation_gain_m)} m · {Packheavy.Trips.Helpers.format_hours(Packheavy.Trips.Helpers.leg_time_h(leg))}<%= if leg_calories = Packheavy.Trips.Helpers.leg_calories(leg, @leader_kg, @loads) do %> · {leg_calories} kcal<% end %>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="fly-to-leg"
                        phx-value-id={leg.id}
                        class="btn btn-ghost btn-xs shrink-0"
                        title="Fly the map to this leg"
                      >
                        Fly
                      </button>
                    </div>
                    <%= if leg_has_elevation?(leg) do %>
                      <div
                        id={"public-leg-chart-#{leg.id}"}
                        phx-hook="LegChart"
                        phx-update="ignore"
                        data-leg-id={leg.id}
                        data-color={leg.color}
                        data-track={Jason.encode!(leg.track)}
                      >
                        {Phoenix.HTML.raw(leg_elevation_svg(leg))}
                      </div>
                    <% end %>
                    <div :if={leg.notes && leg.notes != ""} class="markdown text-sm opacity-90 border-t border-base-300 pt-2">
                      {PackheavyWeb.Markdown.render(leg.notes)}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </details>

        <!-- Pack — collapsible. Open by default. -->
        <details class="card bg-base-200" open>
          <summary class="cursor-pointer p-4 font-semibold">Pack</summary>
          <div class="p-4 pt-0 space-y-4">
            <% food_g = Map.get(totals, :food_weight_g, 0) %>
            <% days = TripShow.trip_days(@trip) %>
            <% kcal_per_g =
              if food_g > 0,
                do: :erlang.float_to_binary(calories / food_g, decimals: 1),
                else: nil %>

            <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
              <div class="space-y-1">
                <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Weight breakdown</h3>
                <TripShow.weight_breakdown trip={@trip} />
              </div>
              <div class="space-y-1">
                <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Resources</h3>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <div class="card bg-base-100 p-3">
                    <div class="text-xs opacity-70">Calories carried</div>
                    <div class="text-lg font-semibold tabular-nums">{calories} kcal</div>
                    <div :if={days} class="text-xs opacity-50">
                      ~{div(calories, max(days, 1))} kcal/day
                    </div>
                  </div>
                  <div class="card bg-base-100 p-3">
                    <div class="text-xs opacity-70">Power</div>
                    <div class="text-lg font-semibold tabular-nums">{Map.get(totals, :power_mah, 0)} mAh</div>
                  </div>
                </div>
              </div>
            </div>

            <%= if @trip.trip_items == [] do %>
              <p class="opacity-70 italic">No items on this trip.</p>
            <% else %>
              <div class="space-y-5">
                <section :for={{cat, label} <- @visible_categories}>
                  <div class="flex justify-between items-baseline border-b border-success pb-0.5 mb-1">
                    <h3 class="text-success text-xs font-bold uppercase tracking-wide">{label}</h3>
                    <span class="text-success text-xs tabular-nums opacity-80">
                      <span :if={cap = @section_capacity.(cat)} class="mr-2">Σ {TripShow.format_capacity(cap)}L</span><span :if={kcal = @section_calories.(cat)} class="mr-2">Σ {kcal}kcal<span :if={cat == :food && kcal_per_g}> · avg {kcal_per_g} kcal/g</span></span>{@section_weight.(cat)}g
                    </span>
                  </div>
                  <ul class="divide-y divide-base-300">
                    <li
                      :for={ti <- Map.get(@grouped, cat, [])}
                      class="grid grid-cols-[1fr_3rem_4.5rem_5rem_3.5rem_5.5rem] items-center gap-2 py-2 px-1 text-sm"
                    >
                      <span class="min-w-0 truncate">
                        <span :if={ti.item.brand} class="opacity-60 mr-1 inline-block max-w-[7rem] sm:max-w-none truncate align-bottom">{ti.item.brand}</span>
                        {ti.item.title}
                      </span>
                      <span class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                        <%= if cap = TripShow.pack_capacity(ti) do %>{TripShow.format_capacity(cap)}L<% end %>
                      </span>
                      <span class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                        <%= if kcal = TripShow.food_calories(ti) do %>{kcal}kcal<% end %>
                      </span>
                      <span class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                        <%= if ti.qty > 1 do %>
                          {ti.item.weight_g || 0}g×{ti.qty}
                        <% else %>
                          ×1
                        <% end %>
                      </span>
                      <span class="opacity-60 text-xs tabular-nums text-right">
                        {(ti.item.weight_g || 0) * ti.qty}g
                      </span>
                      <span class="badge badge-ghost badge-xs whitespace-nowrap justify-self-center">{TripShow.carry_mode_label(ti.carry_mode)}</span>
                    </li>
                  </ul>
                </section>
              </div>
            <% end %>
          </div>
        </details>
      </div>
    </main>
    """
  end

  defp leg_palette,
    do: ~w(#dc2626 #2563eb #16a34a #ca8a04 #9333ea #0891b2 #db2777 #65a30d)

  defp leg_has_elevation?(%{track: track}),
    do: Enum.any?(track, &(Map.get(&1, :ele) || Map.get(&1, "ele")))

  defp day_date(%{start_date: %Date{} = sd}, day) when is_integer(day) and day >= 1 do
    sd |> Date.add(day - 1) |> Calendar.strftime("%a %d %b")
  end

  defp day_date(_, _), do: nil

  defp day_summary(legs) do
    distance_km = legs |> Enum.map(& &1.distance_m) |> Enum.sum() |> Kernel./(1000.0)

    time_h =
      Enum.reduce(legs, 0.0, fn leg, acc ->
        acc + (Packheavy.Trips.Helpers.leg_time_h(leg) || 0.0)
      end)

    "#{:erlang.float_to_binary(distance_km, decimals: 1)} km · #{Packheavy.Trips.Helpers.format_hours(time_h)}"
  end

  defp leg_elevation_svg(%{track: track, color: color, id: _id}) do
    samples =
      track
      |> Enum.filter(&(track_field(&1, :ele) != nil))
      |> Enum.map(fn pt -> %{d: track_field(pt, :d), ele: track_field(pt, :ele)} end)

    case samples do
      [] ->
        ""

      [_only] ->
        ""

      _ ->
        {min_e, max_e} = samples |> Enum.map(& &1.ele) |> Enum.min_max()
        total_d = samples |> List.last() |> Map.get(:d) |> max(1.0)
        e_span = max(max_e - min_e, 1.0)

        plotted =
          Enum.map(samples, fn s ->
            x = s.d / total_d * 800
            y = 200 - (s.ele - min_e) / e_span * 180 - 10
            Map.merge(s, %{x: x, y: y})
          end)

        segments_svg =
          plotted
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map_join("", fn [a, b] ->
            slope = signed_slope_pct(a, b)
            fill = incline_color(slope)
            "<polygon points=\"#{fmt(a.x)},190 #{fmt(a.x)},#{fmt(a.y)} #{fmt(b.x)},#{fmt(b.y)} #{fmt(b.x)},190\" fill=\"#{fill}\" stroke=\"none\" />"
          end)

        polyline_str =
          Enum.map_join(plotted, " ", fn p -> "#{fmt(p.x)},#{fmt(p.y)}" end)

        """
        <svg viewBox="0 0 800 200" class="w-full h-32 select-none" style="color: #{color}">
          #{segments_svg}
          <polyline points="#{polyline_str}" fill="none" stroke="currentColor" stroke-width="1.5" />
          <text x="4" y="14" class="fill-base-content text-xs opacity-70">#{round(max_e)} m</text>
          <text x="4" y="196" class="fill-base-content text-xs opacity-70">#{round(min_e)} m</text>
          <text x="796" y="196" text-anchor="end" class="fill-base-content text-xs opacity-70">#{:erlang.float_to_binary(total_d / 1000, decimals: 1)} km</text>
        </svg>
        """
    end
  end

  defp signed_slope_pct(%{d: d1, ele: e1}, %{d: d2, ele: e2}) do
    dh = d2 - d1
    if dh > 0, do: (e2 - e1) / dh * 100, else: 0.0
  end

  defp incline_color(slope) do
    cond do
      slope >= 12.0 -> "rgba(239,68,68,0.55)"
      slope >= 6.0 -> "rgba(249,115,22,0.5)"
      slope >= 3.0 -> "rgba(250,204,21,0.45)"
      slope <= -18.0 -> "rgba(239,68,68,0.55)"
      slope <= -10.0 -> "rgba(249,115,22,0.5)"
      slope <= -5.0 -> "rgba(250,204,21,0.45)"
      true -> "rgba(74,222,128,0.35)"
    end
  end

  defp fmt(n), do: :erlang.float_to_binary(n / 1.0, decimals: 1)

  defp track_field(%{} = m, key) when is_atom(key),
    do: Map.get(m, key) || Map.get(m, Atom.to_string(key))

  # Same canonical category order as TripLive.Show.category_order/0,
  # which is private there. Duplicated to keep the public view's
  # category labelling self-contained.
  defp category_order do
    [
      {:pack, "Packs"},
      {:shelter, "Shelter"},
      {:sleep, "Sleep"},
      {:clothing, "Clothing"},
      {:cooking, "Cooking"},
      {:water_container, "Water"},
      {:food, "Food"},
      {:electronic, "Electronics"},
      {:camera_lens, "Camera lenses"},
      {:power, "Powerbanks"},
      {:battery, "Batteries"},
      {:cable, "Cables"},
      {:hygiene, "Hygiene"},
      {:first_aid, "First aid"},
      {:tools, "Tools"},
      {:containers, "Containers"},
      {:other, "Other"}
    ]
  end
end
