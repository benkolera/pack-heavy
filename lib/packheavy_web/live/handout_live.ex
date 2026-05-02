defmodule PackheavyWeb.HandoutLive do
  @moduledoc """
  Print/PDF-friendly trip handout — the equivalent of the public share
  view *plus* private contact details (hikers' phones / satellite SMS /
  trackers, emergency + daily check-in contacts). Only reachable by the
  trip's owner via the regular auth pipeline.

  The intended use is `Cmd+P` → "Save as PDF" to produce a single
  document you can email to family before a trip. Layout is plain
  always-open sections (no `<details>`) since the print CSS hides
  `<summary>` elements.
  """

  use PackheavyWeb, :live_view

  alias Packheavy.Trips.Trip
  alias PackheavyWeb.TripLive.Show, as: TripShow

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    trip =
      Ash.get!(Trip, id,
        actor: user,
        load: [
          :validation_report,
          :trip_legs,
          :trip_hikers,
          :trip_contacts,
          trip_items: [:item]
        ]
      )

    {:ok,
     socket
     |> assign(:page_title, "Packheavy: #{trip.name} — handout")
     |> assign(:trip, trip)}
  end

  @impl true
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
    emergency = Enum.filter(assigns.trip.trip_contacts, &(&1.kind == :emergency_primary))
    daily = Enum.filter(assigns.trip.trip_contacts, &(&1.kind == :daily_checkin))

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
      |> assign(emergency: emergency)
      |> assign(daily: daily)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-5xl mx-auto space-y-4 print:max-w-none">
        <div class="flex items-center gap-2 print:hidden">
          <.link navigate={~p"/trips/#{@trip.id}"} class="link text-sm">← Back to trip</.link>
          <span class="ml-auto text-xs opacity-60">
            Cmd/Ctrl+P → Save as PDF for the offline copy.
          </span>
        </div>

        <header class="border-b border-base-300 pb-3">
          <h1 class="text-2xl font-bold">{@trip.name}</h1>
          <div :if={@trip.start_date || @trip.end_date} class="text-sm opacity-70 mt-1">
            <span :if={@trip.start_date}>{Calendar.strftime(@trip.start_date, "%b %-d, %Y")}</span>
            <span :if={@trip.start_date && @trip.end_date} class="mx-1">→</span>
            <span :if={@trip.end_date}>{Calendar.strftime(@trip.end_date, "%b %-d, %Y")}</span>
          </div>
          <p class="text-xs opacity-60 mt-2">
            Private trip handout — includes contact details. Don't share publicly.
          </p>
        </header>

        <% report = @trip.validation_report || %{totals: %{}} %>
        <% totals = report.totals || %{} %>
        <% calories = Map.get(totals, :calories, 0) %>
        <% food_g = Map.get(totals, :food_weight_g, 0) %>
        <% active = Map.get(totals, :calories_burned_active) %>
        <% resting = Map.get(totals, :calories_burned_resting) %>
        <% time_h = Map.get(totals, :time_h) %>
        <% loads = Map.get(totals, :loads) || Packheavy.Trips.Helpers.pack_loads(@trip) %>
        <% total_distance_m = @legs_with_color |> Enum.map(& &1.distance_m) |> Enum.sum() %>
        <% total_gain_m = @legs_with_color |> Enum.map(& &1.elevation_gain_m) |> Enum.sum() %>

        <!-- Hike overview -->
        <section :if={!empty_overview?(@trip)} class="card bg-base-200 p-4 space-y-2">
          <h2 class="font-semibold">Trip overview</h2>
          <dl class="text-sm grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1">
            <div :if={@trip.area} class="sm:col-span-2"><dt class="opacity-60 inline">Area: </dt><dd class="inline">{@trip.area}</dd></div>
            <div :if={@trip.park_url} class="sm:col-span-2"><dt class="opacity-60 inline">Park: </dt><dd class="inline"><a href={@trip.park_url} class="link link-primary break-all">{@trip.park_url}</a></dd></div>
            <div :if={@trip.route_url} class="sm:col-span-2"><dt class="opacity-60 inline">Route: </dt><dd class="inline"><a href={@trip.route_url} class="link link-primary break-all">{@trip.route_url}</a></dd></div>
            <div :if={@trip.departure_at}><dt class="opacity-60 inline">Depart: </dt><dd class="inline">{format_datetime(@trip.departure_at)}</dd></div>
            <div :if={@trip.return_at}><dt class="opacity-60 inline">Return: </dt><dd class="inline">{format_datetime(@trip.return_at)}</dd></div>
            <div :if={@trip.escalation_criteria} class="sm:col-span-2"><dt class="opacity-60">Escalation criteria:</dt><dd class="whitespace-pre-line">{@trip.escalation_criteria}</dd></div>
            <div :if={@trip.gear_highlights} class="sm:col-span-2"><dt class="opacity-60">Gear highlights:</dt><dd class="whitespace-pre-line">{@trip.gear_highlights}</dd></div>
            <div :if={@trip.notes && @trip.notes != ""} class="sm:col-span-2">
              <dt class="opacity-60">Notes:</dt>
              <dd class="markdown text-sm">{PackheavyWeb.Markdown.render(@trip.notes)}</dd>
            </div>
          </dl>
        </section>

        <!-- Hikers (with private contact info) -->
        <section :if={@trip.trip_hikers != []} class="card bg-base-200 p-4 space-y-2">
          <h2 class="font-semibold">Hiking group</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-2 text-sm">
            <%= for h <- Enum.sort_by(@trip.trip_hikers, & &1.position) do %>
              <%= if h.role == :leader do %>
                <div class="sm:col-span-2 lg:col-span-3">
                  <span class="font-semibold">
                    {h.name}
                    <span class="badge badge-primary badge-xs ml-1">Leader</span>
                  </span>
                  <span class="opacity-70 ml-2">
                    <span :if={h.phone}>📱 <a href={"tel:#{h.phone}"} class="link">{h.phone}</a></span>
                    <span :if={h.satellite_sms} class="ml-2">🛰 <a href={"tel:#{h.satellite_sms}"} class="link">{h.satellite_sms}</a></span>
                  </span>
                  <div :if={h.plb_hex_id || h.plb_serial} class="opacity-70 mt-1 text-xs">
                    📡 PLB<span :if={h.plb_hex_id} class="ml-1">Hex: <span class="font-mono">{h.plb_hex_id}</span></span><span :if={h.plb_serial} class="ml-2">Serial: {h.plb_serial}</span>
                  </div>
                  <div :if={h.location_tracker_url} class="opacity-70 break-all mt-1">
                    Tracker: <a href={h.location_tracker_url} class="link link-primary">{h.location_tracker_url}</a><span :if={h.location_tracker_password}> · "{h.location_tracker_password}"</span>
                  </div>
                  <span :if={h.notes} class="block opacity-70 whitespace-pre-line mt-1 text-xs">{h.notes}</span>
                </div>
              <% else %>
                <div>
                  <div class="font-semibold">{h.name}</div>
                  <div :if={h.phone} class="opacity-70">📱 <a href={"tel:#{h.phone}"} class="link">{h.phone}</a></div>
                  <div :if={h.plb_hex_id || h.plb_serial} class="opacity-70 text-xs">
                    📡 PLB<span :if={h.plb_hex_id} class="ml-1">Hex: <span class="font-mono">{h.plb_hex_id}</span></span><span :if={h.plb_serial} class="ml-2">Serial: {h.plb_serial}</span>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </section>

        <!-- Emergency + daily check-in contacts: combined card, two columns. -->
        <section :if={@emergency != [] or @daily != []} class="card bg-base-200 p-4 space-y-3">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div :if={@emergency != []} class="space-y-2">
              <h2 class="font-semibold">Emergency contact</h2>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-2 text-sm">
                <div :for={c <- Enum.sort_by(@emergency, & &1.position)}>
                  <div class="font-semibold">
                    {c.name}
                    <span :if={c.relationship} class="opacity-60 font-normal text-xs ml-1">({c.relationship})</span>
                  </div>
                  <div :if={c.phone} class="opacity-70">📱 <a href={"tel:#{c.phone}"} class="link">{c.phone}</a></div>
                  <div :if={c.escalation_criteria} class="opacity-70 whitespace-pre-line mt-1 text-xs">{c.escalation_criteria}</div>
                </div>
              </div>
            </div>
            <div :if={@daily != []} class="space-y-2">
              <h2 class="font-semibold">Daily check-in contacts</h2>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-2 text-sm">
                <div :for={c <- Enum.sort_by(@daily, & &1.position)}>
                  <div class="font-semibold">
                    {c.name}
                    <span :if={c.relationship} class="opacity-60 font-normal text-xs ml-1">({c.relationship})</span>
                  </div>
                  <div :if={c.phone} class="opacity-70">📱 <a href={"tel:#{c.phone}"} class="link">{c.phone}</a></div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- Headline numbers, sat above the route so the reader has
             distance/elevation/calories/pack-weight context immediately
             before scrolling into the per-leg details. In print we
             force a fresh page here so the tile row + the route map
             don't get split across two pages. -->
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-7 print:grid-cols-4 gap-2 print:break-before-page">
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
            <div class="text-lg font-semibold tabular-nums">{:erlang.float_to_binary(loads.full_kg, decimals: 2)} kg</div>
            <div :if={loads.sidequest_kg > 0} class="text-xs opacity-50 tabular-nums" title="Worn + day-pack only">
              sidequest: {:erlang.float_to_binary(loads.sidequest_kg, decimals: 2)} kg
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

        <!-- Route -->
        <section :if={@has_legs?} class="card bg-base-200 p-4 space-y-4">
          <h2 class="font-semibold">Route</h2>
          <div
            id="handout-route-map"
            phx-hook="RouteMap"
            phx-update="ignore"
            data-legs={@legs_payload_json}
            class="w-full h-[500px] print:h-[400px] rounded print:break-inside-avoid"
          >
          </div>

          <div class="space-y-6">
            <div :for={{day, day_legs} <- @legs_by_day} class="border-t-2 border-base-300 pt-3 first:border-t-0 first:pt-0">
              <div class="flex items-baseline gap-3 flex-wrap mb-2 print:break-after-avoid">
                <h3 class="text-base font-bold uppercase tracking-wide">
                  Day {day}<span :if={date = day_date(@trip, day)} class="opacity-70 font-semibold normal-case ml-2 text-sm">{date}</span>
                </h3>
                <span :if={day_legs != []} class="text-sm opacity-70 tabular-nums">
                  {day_summary(day_legs)}
                </span>
                <span :if={day_legs == []} class="text-xs opacity-50 italic">no legs</span>
              </div>

              <div :for={leg <- day_legs} class="card bg-base-100 p-3 mb-2 space-y-2 print:break-inside-avoid">
                <div class="flex items-start gap-2">
                  <span class="inline-block w-3 h-3 rounded-sm shrink-0 mt-1.5" style={"background-color: #{leg.color}"}></span>
                  <div class="flex-1 min-w-0">
                    <div class="text-sm font-semibold break-words">
                      {leg.name}
                      <span :if={leg.sidequest} class="badge badge-xs badge-info ml-1 align-middle">sidequest</span>
                    </div>
                    <div class="text-xs opacity-70 tabular-nums mt-0.5">
                      {:erlang.float_to_binary(leg.distance_m / 1000, decimals: 2)} km · +{round(leg.elevation_gain_m)} m · {Packheavy.Trips.Helpers.format_hours(Packheavy.Trips.Helpers.leg_time_h(leg))}
                    </div>
                  </div>
                </div>
                <div :if={leg.notes && leg.notes != ""} class="markdown text-sm opacity-90 border-t border-base-300 pt-2">
                  {PackheavyWeb.Markdown.render(leg.notes)}
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- Pack -->
        <section class="card bg-base-200 p-4 space-y-4">
          <h2 class="font-semibold">Pack</h2>

          <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
            <div class="space-y-1">
              <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Weight breakdown</h3>
              <TripShow.weight_breakdown trip={@trip} />
            </div>
            <div class="space-y-1">
              <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Carry mode</h3>
              <div class="grid grid-cols-3 gap-2">
                <div class="card bg-base-100 p-3">
                  <div class="text-xs opacity-70">Worn</div>
                  <div class="text-lg font-semibold tabular-nums">{:erlang.float_to_binary((loads.by_carry.worn + loads.water_by_carry.worn) / 1000, decimals: 2)} kg</div>
                </div>
                <div class="card bg-base-100 p-3">
                  <div class="text-xs opacity-70">Day pack</div>
                  <div class="text-lg font-semibold tabular-nums">{:erlang.float_to_binary((loads.by_carry.day_pack + loads.water_by_carry.day_pack) / 1000, decimals: 2)} kg</div>
                </div>
                <div class="card bg-base-100 p-3">
                  <div class="text-xs opacity-70">Main pack</div>
                  <div class="text-lg font-semibold tabular-nums">{:erlang.float_to_binary((loads.by_carry.main_pack + loads.water_by_carry.main_pack) / 1000, decimals: 2)} kg</div>
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
                    <span :if={cap = @section_capacity.(cat)} class="mr-2">Σ {TripShow.format_capacity(cap)}L</span><span :if={kcal = @section_calories.(cat)} class="mr-2">Σ {kcal}kcal<%= if cat == :food && food_g > 0 do %> · avg {:erlang.float_to_binary(calories / food_g, decimals: 1)} kcal/g<% end %></span>{@section_weight.(cat)}g
                  </span>
                </div>
                <ul class="divide-y divide-base-300">
                  <li
                    :for={ti <- Map.get(@grouped, cat, [])}
                    class="grid grid-cols-[1fr_3rem_4.5rem_5rem_3.5rem_5.5rem] items-center gap-2 py-2 px-1 text-sm"
                  >
                    <span class="min-w-0 truncate">
                      <span :if={ti.item.brand} class="opacity-60 mr-1 inline-block max-w-[7rem] sm:max-w-none truncate align-bottom">{ti.item.brand}</span>{ti.item.title}
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
        </section>
      </div>
    </Layouts.app>
    """
  end

  # ---- helpers (private; some duplicate PublicTripLive — fine for now) ----

  defp leg_palette,
    do: ~w(#dc2626 #2563eb #16a34a #ca8a04 #9333ea #0891b2 #db2777 #65a30d)

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

  defp empty_overview?(trip) do
    is_nil(trip.area) and is_nil(trip.park_url) and is_nil(trip.route_url) and
      is_nil(trip.departure_at) and is_nil(trip.return_at) and
      is_nil(trip.escalation_criteria) and is_nil(trip.gear_highlights) and
      (is_nil(trip.notes) or trip.notes == "")
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

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
