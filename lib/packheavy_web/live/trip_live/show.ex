defmodule PackheavyWeb.TripLive.Show do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Trips

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    user = socket.assigns.current_user

    rechargeable_battery_ids =
      Inventory.list_battery_types!(actor: user)
      |> Enum.filter(& &1.rechargeable)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    initial_tab = parse_tab(params["tab"])

    socket =
      socket
      |> assign(:trip_id, id)
      |> assign(:tab, initial_tab)
      |> assign(:items, Inventory.list_items!(actor: user))
      |> assign(:kits, Inventory.list_kits!(actor: user))
      |> assign(:rechargeable_battery_ids, rechargeable_battery_ids)
      |> assign(:picker_open, false)
      |> assign(:leg_modal, nil)
      |> allow_upload(:leg_gpx,
        accept: ~w(.gpx application/gpx+xml),
        max_entries: 1,
        max_file_size: 50_000_000
      )
      |> reload()

    {:ok, assign(socket, :editing_details?, false)}
  end

  defp existing_slots_on_trip(trip) do
    trip.trip_items
    |> Enum.group_by(& &1.item_id)
    |> Map.new(fn {iid, rows} ->
      slots = Enum.map(rows, fn r -> %{qty: r.qty, carry_mode: r.carry_mode || :main_pack} end)
      {iid, slots}
    end)
  end

  defp max_qty_for_trip(items) do
    Map.new(items, fn item -> {item.id, item.qty || 0} end)
  end

  defp reload(socket) do
    user = socket.assigns.current_user

    trip =
      Ash.get!(Packheavy.Trips.Trip, socket.assigns.trip_id,
        actor: user,
        load: [
          :validation_report,
          :trip_legs,
          :trip_hikers,
          trip_items: [:item],
          trip_kits: [:kit]
        ]
      )

    socket
    |> assign(:trip, trip)
    |> assign(:page_title, "Packheavy: #{trip.name} (#{trip_state_label(trip.state)})")
  end

  defp trip_state_label(:draft), do: "Planning"
  defp trip_state_label(:packing), do: "Packing"
  defp trip_state_label(:complete), do: "Complete"

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("open_picker", _, socket) do
    {:noreply, assign(socket, :picker_open, true)}
  end

  def handle_event("close_picker", _, socket) do
    {:noreply, assign(socket, :picker_open, false)}
  end

  def handle_event("add_kit", %{"kit_id" => kit_id}, socket) do
    trip = socket.assigns.trip
    Trips.add_kit!(trip, kit_id, actor: socket.assigns.current_user)
    {:noreply, reload(socket)}
  end

  def handle_event("remove_item", %{"id" => id}, socket) do
    Packheavy.Trips.TripItem
    |> Ash.get!(id, actor: socket.assigns.current_user)
    |> Ash.destroy!(actor: socket.assigns.current_user)

    {:noreply, reload(socket)}
  end

  def handle_event("toggle_packed", %{"id" => id}, socket) do
    ti = Ash.get!(Packheavy.Trips.TripItem, id, actor: socket.assigns.current_user)
    Trips.set_packed!(ti, !ti.packed, actor: socket.assigns.current_user)
    {:noreply, reload(socket)}
  end

  def handle_event("toggle_charged", %{"id" => id}, socket) do
    ti = Ash.get!(Packheavy.Trips.TripItem, id, actor: socket.assigns.current_user)
    Trips.set_charged!(ti, !ti.charged, actor: socket.assigns.current_user)
    {:noreply, reload(socket)}
  end

  def handle_event("toggle_tested", %{"id" => id}, socket) do
    ti = Ash.get!(Packheavy.Trips.TripItem, id, actor: socket.assigns.current_user)
    Trips.set_tested!(ti, !ti.tested, actor: socket.assigns.current_user)
    {:noreply, reload(socket)}
  end

  def handle_event("start_packing", _, socket) do
    socket.assigns.trip
    |> Ash.Changeset.for_update(:start_packing)
    |> Ash.update!(actor: socket.assigns.current_user)

    {:noreply, socket |> assign(:tab, :pack) |> reload()}
  end

  def handle_event("enable_sharing", _, socket) do
    Trips.enable_trip_sharing!(socket.assigns.trip, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Public link enabled.") |> reload()}
  end

  def handle_event("disable_sharing", _, socket) do
    Trips.disable_trip_sharing!(socket.assigns.trip, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Public link revoked.") |> reload()}
  end

  def handle_event("save_details", %{"details" => params}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      name: params["name"],
      start_date: blank_to_nil(params["start_date"]),
      end_date: blank_to_nil(params["end_date"])
    }

    Trips.update_trip!(socket.assigns.trip, attrs, actor: user)

    {:noreply,
     socket
     |> put_flash(:info, "Trip details saved.")
     |> assign(:editing_details?, false)
     |> reload()}
  end

  def handle_event("edit_details", _, socket),
    do: {:noreply, assign(socket, :editing_details?, true)}

  def handle_event("cancel_edit_details", _, socket),
    do: {:noreply, assign(socket, :editing_details?, false)}

  def handle_event("complete", _, socket) do
    socket.assigns.trip
    |> Ash.Changeset.for_update(:complete)
    |> Ash.update!(actor: socket.assigns.current_user)

    {:noreply, socket |> put_flash(:info, "Trip complete. Food qty decremented.") |> reload()}
  end

  # ---- Route tab events --------------------------------------------------

  def handle_event("validate-leg", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-leg-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :leg_gpx, ref)}
  end

  def handle_event("add-leg", params, socket) do
    user = socket.assigns.current_user
    trip = socket.assigns.trip

    next_position = next_position(trip)
    day = parse_int(params["day"], 1)

    case consume_uploaded_entries(socket, :leg_gpx, fn %{path: path}, entry ->
           {:ok, {entry.client_name, File.read!(path) |> Packheavy.Gpx.parse()}}
         end) do
      [{name, {:ok, parsed}}] ->
        track = Packheavy.Trips.Helpers.canonical_track(parsed.points)
        derived_name = leg_name_from_filename(name) || "Leg #{next_position}"

        Trips.create_trip_leg!(
          %{
            trip_id: trip.id,
            position: next_position,
            day: day,
            name: blank_to_nil(params["name"]) || derived_name,
            sidequest: params["sidequest"] == "true",
            pace_kmh: parse_float(params["pace_kmh"], 4.0),
            notes: blank_to_nil(params["notes"]),
            gpx_filename: name,
            distance_m: parsed.stats.distance_m,
            elevation_gain_m: parsed.stats.elevation_gain_m,
            point_count: parsed.stats.point_count,
            track: track
          },
          actor: user
        )

        {:noreply,
         socket
         |> put_flash(:info, "Leg added: #{name}.")
         |> assign(:leg_modal, nil)
         |> reload()
         |> push_legs_update()}

      [{name, {:error, reason}}] ->
        {:noreply, put_flash(socket, :error, "Could not parse #{name}: #{reason}")}

      [] ->
        {:noreply, put_flash(socket, :error, "Pick a GPX file first.")}
    end
  end

  def handle_event("delete-leg", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    Packheavy.Trips.TripLeg
    |> Ash.get!(id, actor: user)
    |> Ash.destroy!(actor: user)

    {:noreply, socket |> reload() |> push_legs_update()}
  end

  def handle_event("move-leg", %{"id" => id, "dir" => dir}, socket) do
    user = socket.assigns.current_user
    legs = socket.assigns.trip.trip_legs

    with %{} = leg <- Enum.find(legs, &(&1.id == id)),
         same_day = Enum.filter(legs, &(&1.day == leg.day)),
         neighbour when not is_nil(neighbour) <- neighbour_in_direction(same_day, leg, dir) do
      swap_positions(leg, neighbour, user)
      {:noreply, socket |> reload() |> push_legs_update()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open-add-leg", %{"day" => day}, socket) do
    {:noreply, assign(socket, :leg_modal, %{mode: :add, day: parse_int(day, 1)})}
  end

  def handle_event("open-edit-leg", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.trip.trip_legs, &(&1.id == id)) do
      nil -> {:noreply, socket}
      leg -> {:noreply, assign(socket, :leg_modal, %{mode: :edit, leg: leg})}
    end
  end

  def handle_event("close-leg-modal", _, socket) do
    {:noreply, assign(socket, :leg_modal, nil)}
  end

  def handle_event("save-leg-edit", %{"leg_id" => id} = params, socket) do
    user = socket.assigns.current_user

    case Enum.find(socket.assigns.trip.trip_legs, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, :leg_modal, nil)}

      leg ->
        new_day = parse_int(params["day"], leg.day)

        attrs = %{
          name: blank_to_nil(params["name"]) || leg.name,
          sidequest: params["sidequest"] == "true",
          pace_kmh: parse_float(params["pace_kmh"], leg.pace_kmh),
          notes: blank_to_nil(params["notes"])
        }

        attrs =
          if new_day != leg.day do
            attrs
            |> Map.put(:day, new_day)
            |> Map.put(:position, next_position(socket.assigns.trip))
          else
            attrs
          end

        Trips.update_trip_leg!(leg, attrs, actor: user)
        socket = reload(socket)

        socket =
          if new_day != leg.day do
            renumber_leg_positions!(socket.assigns.trip.trip_legs, user)
            reload(socket)
          else
            socket
          end

        {:noreply, socket |> assign(:leg_modal, nil) |> push_legs_update()}
    end
  end

  def handle_event("fly-to-leg", %{"id" => id}, socket) do
    {:noreply, push_event(socket, "gpx:fly", %{leg_id: id})}
  end

  defp neighbour_in_direction(legs, %{position: pos}, "up") do
    legs |> Enum.filter(&(&1.position < pos)) |> Enum.max_by(& &1.position, fn -> nil end)
  end

  defp neighbour_in_direction(legs, %{position: pos}, "down") do
    legs |> Enum.filter(&(&1.position > pos)) |> Enum.min_by(& &1.position, fn -> nil end)
  end

  # Three-step swap with a sentinel since (trip_id, position) is unique
  # — Postgres rejects a direct A↔B swap.
  defp swap_positions(a, b, user) do
    a_pos = a.position
    b_pos = b.position
    Trips.update_trip_leg!(a, %{position: -1}, actor: user)
    Trips.update_trip_leg!(b, %{position: a_pos}, actor: user)

    a
    |> Map.put(:position, -1)
    |> Trips.update_trip_leg!(%{position: b_pos}, actor: user)
  end

  defp leg_name_from_filename(nil), do: nil

  defp leg_name_from_filename(filename) do
    filename
    |> Path.rootname()
    |> String.replace(~r/[_-]+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      s -> s
    end
  end

  # Pushes a `route:legs-updated` event to the RouteMap hook with the
  # current canonical legs payload. Used after any leg mutation so the
  # already-mounted Leaflet map (which has `phx-update="ignore"`)
  # refreshes its polylines without a full page reload.
  defp push_legs_update(socket) do
    push_event(socket, "route:legs-updated", %{legs: build_legs_payload(socket.assigns.trip)})
  end

  defp build_legs_payload(%{trip_legs: legs}) when is_list(legs) do
    palette = leg_palette()

    legs
    |> Enum.with_index()
    |> Enum.map(fn {leg, idx} ->
      color = Enum.at(palette, rem(idx, length(palette)))
      %{
        id: leg.id,
        name: leg.name,
        color: color,
        track: Packheavy.Trips.Helpers.slim_track_for_map(leg.track)
      }
    end)
  end

  defp build_legs_payload(_), do: []

  # 8-colour palette cycled per leg. Picked for distinguishability on
  # the green/grey OpenTopoMap background; matches the chart colour for
  # each leg by passing the same hex through to the SVG.
  defp leg_palette, do: ~w(#dc2626 #2563eb #16a34a #ca8a04 #9333ea #0891b2 #db2777 #65a30d)

  defp next_position(%{trip_legs: []}), do: 1

  defp next_position(%{trip_legs: legs}),
    do: (legs |> Enum.map(& &1.position) |> Enum.max()) + 1

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_float(value, _default) when is_number(value), do: value * 1.0
  defp parse_float(_, default), do: default

  # Two-pass renumber that keeps `position` dense (1..N) across the
  # whole trip, ordered by (day, current_position). Pass 1 moves
  # everyone to a negative sentinel space so the unique-(trip_id,
  # position) constraint isn't temporarily violated, then pass 2
  # assigns the final positives.
  defp renumber_leg_positions!(legs, user) do
    sorted = Enum.sort_by(legs, fn l -> {l.day, l.position} end)

    pass1 =
      sorted
      |> Enum.with_index(1)
      |> Enum.map(fn {leg, idx} ->
        Trips.update_trip_leg!(leg, %{position: -idx}, actor: user)
      end)

    pass1
    |> Enum.with_index(1)
    |> Enum.each(fn {leg, idx} ->
      Trips.update_trip_leg!(leg, %{position: idx}, actor: user)
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v), do: v

  defp parse_tab("route"), do: :route
  defp parse_tab("pack"), do: :pack
  defp parse_tab("complete"), do: :complete
  defp parse_tab(_), do: :plan

  @impl true
  def handle_info({:item_picker_confirm, "trip-item-picker", selected}, socket) do
    user = socket.assigns.current_user
    trip_id = socket.assigns.trip_id

    existing_by_item =
      socket.assigns.trip.trip_items
      |> Enum.group_by(& &1.item_id)

    item_ids =
      MapSet.union(MapSet.new(Map.keys(selected)), MapSet.new(Map.keys(existing_by_item)))

    Enum.each(item_ids, fn item_id ->
      desired_slots = Map.get(selected, item_id, [])
      existing_rows = Map.get(existing_by_item, item_id, [])

      cond do
        desired_slots == [] ->
          Enum.each(existing_rows, &Ash.destroy!(&1, actor: user))

        slot_lists_match?(desired_slots, existing_rows) ->
          :ok

        true ->
          # Slot list changed — destroy all existing rows for this item
          # and recreate one TripItem per desired slot. Loses
          # source/source_kit_id attribution; fine for v1.
          Enum.each(existing_rows, &Ash.destroy!(&1, actor: user))

          Enum.each(desired_slots, fn slot ->
            Trips.add_trip_item!(
              %{
                trip_id: trip_id,
                item_id: item_id,
                qty: slot.qty,
                source: :direct,
                carry_mode: slot.carry_mode
              },
              actor: user
            )
          end)
      end
    end)

    {:noreply,
     socket
     |> assign(:picker_open, false)
     |> put_flash(:info, "Trip items updated.")
     |> reload()}
  end

  # Treats slot lists as multisets of {qty, carry_mode} so order doesn't
  # matter. Equal multisets → no change needed.
  defp slot_lists_match?(slots, rows) do
    desired = slots |> Enum.map(fn s -> {s.qty, s.carry_mode} end) |> Enum.sort()

    actual =
      rows |> Enum.map(fn r -> {r.qty, r.carry_mode || :main_pack} end) |> Enum.sort()

    desired == actual
  end

  @doc "Inclusive day count for the trip; nil if either date is missing."
  def trip_days(%{start_date: %Date{} = sd, end_date: %Date{} = ed}) do
    Date.diff(ed, sd) + 1
  end

  def trip_days(_), do: nil

  def needs_charging?(ti, rechargeable_battery_ids) do
    case ti.item && ti.item.category_data do
      # Devices with a built-in rechargeable cell — you charge the device.
      %Ash.Union{value: %Packheavy.Inventory.Item.Electronic{power_source: :built_in}} ->
        true

      # Powerbanks always need charging before a trip.
      %Ash.Union{value: %Packheavy.Inventory.Item.Power{}} ->
        true

      # Battery items themselves, when their type is rechargeable. The qty on
      # the row covers "all of them" — one tick = the whole pack is charged.
      %Ash.Union{value: %Packheavy.Inventory.Item.Battery{battery_type_id: bt_id}}
      when not is_nil(bt_id) ->
        MapSet.member?(rechargeable_battery_ids, bt_id)

      # Devices that use replaceable batteries don't charge themselves —
      # the rechargeable Battery item handles that.
      _ ->
        false
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.link navigate={~p"/trips"} class="link text-sm">← Trips</.link>
      <div class="flex flex-wrap justify-between items-center gap-2">
        <h1 class="text-2xl font-bold">
          {@trip.name}
          <span class="badge ml-2">{@trip.state}</span>
        </h1>
        <.share_panel trip={@trip} socket={@socket} />
      </div>

      <.trip_details_panel trip={@trip} editing?={@editing_details?} />

      <div role="tablist" class="tabs tabs-boxed">
        <.link navigate={~p"/trips/#{@trip.id}"} role="tab" class="tab">Details</.link>
        <a
          role="tab"
          class={["tab", @tab == :route && "tab-active"]}
          phx-click="set_tab"
          phx-value-tab="route"
        >
          Route
        </a>
        <a
          role="tab"
          class={["tab", @tab == :plan && "tab-active"]}
          phx-click="set_tab"
          phx-value-tab="plan"
        >
          Plan
        </a>
        <a
          role="tab"
          class={["tab", @tab == :pack && "tab-active"]}
          phx-click="set_tab"
          phx-value-tab="pack"
        >
          Pack
        </a>
        <a
          role="tab"
          class={["tab", @tab == :complete && "tab-active"]}
          phx-click="set_tab"
          phx-value-tab="complete"
        >
          Complete
        </a>
      </div>

      <%= case @tab do %>
        <% :route -> %>
          <.route_tab trip={@trip} uploads={@uploads} leg_modal={@leg_modal} />
        <% :plan -> %>
          <.plan_tab trip={@trip} items={@items} kits={@kits} />
        <% :pack -> %>
          <.pack_tab trip={@trip} rechargeable_battery_ids={@rechargeable_battery_ids} />
        <% :complete -> %>
          <.complete_tab trip={@trip} />
      <% end %>

      <%= if @picker_open do %>
        <.live_component
          module={PackheavyWeb.ItemPicker}
          id="trip-item-picker"
          items={@items}
          existing_slots={existing_slots_on_trip(@trip)}
          max_qty_for={max_qty_for_trip(@items)}
          title={"Items on " <> @trip.name}
          confirm_label="Save"
          close_event="close_picker"
          with_carry_mode={true}
        />
      <% end %>
    </Layouts.app>
    """
  end

  # Public so PackheavyWeb.TripDetailsLive can reuse the same summary
  # row at the top of the hike-details page. The pack planner and the
  # details page should share this header to keep the calorie/burn
  # numbers visible on both.
  attr :trip, :any, required: true
  attr :editing?, :boolean, required: true

  def trip_details_panel(assigns) do
    days = trip_days(assigns.trip)
    distance_km = Packheavy.Trips.Helpers.trip_distance_km(assigns.trip)
    elevation_m = Packheavy.Trips.Helpers.trip_elevation_gain_m(assigns.trip)
    leader_kg = Packheavy.Trips.Helpers.leader_weight_kg(assigns.trip)
    time_h = Packheavy.Trips.Helpers.trip_time_h(assigns.trip)

    assigns =
      assigns
      |> assign(:days, days)
      |> assign(:summary_distance_km, distance_km)
      |> assign(:summary_elevation_m, elevation_m)
      |> assign(:summary_weight_kg, leader_kg)
      |> assign(:summary_time_h, time_h)

    ~H"""
    <div class="bg-base-200 rounded p-2 print:hidden text-sm">
      <div class="flex items-center gap-3 flex-wrap">
        <span class="flex items-center gap-3 text-xs opacity-80 tabular-nums flex-1 min-w-0 flex-wrap">
          <span :if={@days} class="flex items-center gap-1 whitespace-nowrap">
            <.icon name="hero-calendar-days-mini" class="size-4 opacity-70" />
            {@days} day{if @days == 1, do: "", else: "s"}
          </span>
          <span
            :if={@summary_distance_km}
            class="flex items-center gap-1 whitespace-nowrap"
            title="Summed from GPX legs"
          >
            <.icon name="hero-map-mini" class="size-4 opacity-70" />
            {:erlang.float_to_binary(@summary_distance_km, decimals: 1)}km
          </span>
          <span
            :if={@summary_elevation_m}
            class="flex items-center gap-1 whitespace-nowrap"
            title="Summed from GPX legs"
          >
            <.icon name="hero-arrow-trending-up-mini" class="size-4 opacity-70" />
            +{round(@summary_elevation_m)}m
          </span>
          <span
            :if={@summary_time_h}
            class="flex items-center gap-1 whitespace-nowrap"
            title="Naismith estimate, summed from per-leg pace"
          >
            <.icon name="hero-clock-mini" class="size-4 opacity-70" />
            {Packheavy.Trips.Helpers.format_hours(@summary_time_h)}
          </span>
          <span
            :if={@summary_weight_kg}
            class="flex items-center gap-1 whitespace-nowrap"
            title="Leader hiker weight"
          >
            <.icon name="hero-scale-mini" class="size-4 opacity-70" />
            {@summary_weight_kg}kg
          </span>
          <span
            :if={!@summary_distance_km && !@summary_elevation_m && !@summary_weight_kg && !@days}
            class="opacity-60 italic"
          >
            no details yet
          </span>
        </span>
        <button
          :if={!@editing?}
          type="button"
          phx-click="edit_details"
          class="btn btn-ghost btn-xs ml-auto"
        >
          <.icon name="hero-pencil-square-mini" class="size-3.5" /> Edit
        </button>
      </div>

      <form
        :if={@editing?}
        phx-submit="save_details"
        class="mt-3 grid grid-cols-1 sm:grid-cols-6 gap-3"
      >
        <label class="flex flex-col gap-1 sm:col-span-6">
          <span class="text-xs opacity-70">Trip name</span>
          <input
            type="text"
            name="details[name]"
            value={@trip.name}
            required
            class="input input-bordered input-sm w-full"
          />
        </label>
        <label class="flex flex-col gap-1 sm:col-span-3">
          <span class="text-xs opacity-70">Start date</span>
          <input
            type="date"
            name="details[start_date]"
            value={@trip.start_date}
            class="input input-bordered input-sm w-full"
          />
        </label>
        <label class="flex flex-col gap-1 sm:col-span-3">
          <span class="text-xs opacity-70">End date</span>
          <input
            type="date"
            name="details[end_date]"
            value={@trip.end_date}
            class="input input-bordered input-sm w-full"
          />
        </label>
        <p class="sm:col-span-6 text-xs opacity-60">
          Distance and elevation come from GPX legs on the Route tab.
          Hiker weight comes from the leader hiker on this page.
        </p>
        <div class="sm:col-span-6 flex justify-end gap-2">
          <button type="button" phx-click="cancel_edit_details" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button class="btn btn-primary btn-sm">Save</button>
        </div>
      </form>
    </div>
    """
  end

  attr :trip, :any, required: true
  attr :socket, :any, required: true

  def share_panel(assigns) do
    share_url =
      if assigns.trip.share_token do
        url(assigns.socket, ~p"/share/trip/#{assigns.trip.share_token}")
      end

    assigns = assign(assigns, :share_url, share_url)

    ~H"""
    <div class="flex items-center gap-1 text-sm print:hidden">
      <.link
        navigate={~p"/trips/#{@trip.id}/handout"}
        class="btn btn-ghost btn-xs"
        title="Private handout (includes contact details). Cmd/Ctrl+P → Save as PDF."
      >
        Handout
      </.link>
      <%= if @share_url do %>
        <button
          type="button"
          id={"copy-share-#{@trip.id}"}
          phx-hook=".CopyShareLink"
          data-url={@share_url}
          class="btn btn-primary btn-xs"
          title={@share_url}
        >
          Copy share link
        </button>
        <button
          type="button"
          phx-click="disable_sharing"
          data-confirm="Stop sharing? The current link will stop working."
          class="btn btn-ghost btn-xs"
          title="Revoke the public link"
        >
          ×
        </button>
      <% else %>
        <button type="button" phx-click="enable_sharing" class="btn btn-ghost btn-xs">
          Share
        </button>
      <% end %>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyShareLink">
        // Three-tier fallback: navigator.clipboard (modern, fails on
        // some iOS Safari setups), document.execCommand('copy') via a
        // hidden textarea (iOS-tested), then a final prompt() the user
        // can long-press in to copy manually.
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const url = this.el.dataset.url
              const original = this.el.textContent
              const flash = () => {
                this.el.textContent = "Copied!"
                setTimeout(() => { this.el.textContent = original }, 1500)
              }

              const legacyCopy = () => {
                const ta = document.createElement("textarea")
                ta.value = url
                ta.setAttribute("readonly", "")
                ta.style.position = "fixed"
                ta.style.top = "0"
                ta.style.left = "0"
                ta.style.width = "1px"
                ta.style.height = "1px"
                ta.style.opacity = "0"
                ta.style.pointerEvents = "none"
                document.body.appendChild(ta)
                // iOS won't select an input unless it's contentEditable
                // and not readonly during the selection itself.
                ta.contentEditable = "true"
                ta.readOnly = false
                const range = document.createRange()
                range.selectNodeContents(ta)
                const sel = window.getSelection()
                sel.removeAllRanges()
                sel.addRange(range)
                ta.setSelectionRange(0, 999999)
                let ok = false
                try { ok = document.execCommand("copy") } catch (_) {}
                document.body.removeChild(ta)
                return ok
              }

              const tryClipboardApi = () => {
                if (!navigator.clipboard || !navigator.clipboard.writeText) {
                  return Promise.reject(new Error("no clipboard api"))
                }
                return navigator.clipboard.writeText(url)
              }

              tryClipboardApi()
                .then(flash)
                .catch(() => {
                  if (legacyCopy()) flash()
                  else prompt("Copy this link:", url)
                })
            })
          }
        }
      </script>
    </div>
    """
  end

  attr :trip, :any, required: true
  attr :items, :list, required: true
  attr :kits, :list, required: true

  defp plan_tab(assigns) do
    grouped =
      assigns.trip.trip_items
      |> Enum.sort_by(fn ti ->
        item = ti.item
        String.downcase("#{(item && item.brand) || ""} #{item && item.title}")
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
          case ti.item && ti.item.category_data do
            %Ash.Union{value: %Packheavy.Inventory.Item.Pack{volume_l: v}} when is_number(v) ->
              v * ti.qty

            _ ->
              0
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
          case ti.item && ti.item.category_data do
            %Ash.Union{value: %Packheavy.Inventory.Item.Food{calories: c}} when is_integer(c) ->
              c * ti.qty

            _ ->
              0
          end
        end)
        |> Enum.sum()

      if total > 0, do: total, else: nil
    end

    assigns =
      assigns
      |> assign(:grouped, grouped)
      |> assign(:visible_categories, visible_categories)
      |> assign(:section_weight, section_weight)
      |> assign(:section_capacity, section_capacity)
      |> assign(:section_calories, section_calories)

    ~H"""
    <% report = @trip.validation_report || %{errors: [], warnings: [], totals: %{}} %>
    <% totals = report.totals || %{} %>
    <% calories = Map.get(totals, :calories, 0) %>
    <% food_g = Map.get(totals, :food_weight_g, 0) %>
    <% days = PackheavyWeb.TripLive.Show.trip_days(@trip) %>
    <% kcal_per_g =
      if food_g > 0,
        do: :erlang.float_to_binary(calories / food_g, decimals: 1),
        else: nil %>

    <% loads = Map.get(totals, :loads) || Packheavy.Trips.Helpers.pack_loads(@trip) %>

    <div class="grid grid-cols-1 xl:grid-cols-2 print:grid-cols-1 gap-4 mt-2">
      <div class="space-y-1">
        <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Weight breakdown</h3>
        <.weight_breakdown trip={@trip} />
        <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide pt-2">Carry mode</h3>
        <div class="grid grid-cols-3 gap-2">
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Worn</div>
            <div class="text-lg font-semibold tabular-nums">
              {:erlang.float_to_binary((loads.by_carry.worn + loads.water_by_carry.worn) / 1000,
                decimals: 2
              )} kg
            </div>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Day pack</div>
            <div class="text-lg font-semibold tabular-nums">
              {:erlang.float_to_binary(
                (loads.by_carry.day_pack + loads.water_by_carry.day_pack) / 1000, decimals: 2)} kg
            </div>
            <div class="text-xs opacity-50 tabular-nums">
              sidequest load: {:erlang.float_to_binary(loads.sidequest_kg, decimals: 2)} kg
            </div>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Main pack</div>
            <div class="text-lg font-semibold tabular-nums">
              {:erlang.float_to_binary(
                (loads.by_carry.main_pack + loads.water_by_carry.main_pack) / 1000, decimals: 2)} kg
            </div>
            <div class="text-xs opacity-50 tabular-nums">
              full carry: {:erlang.float_to_binary(loads.full_kg, decimals: 2)} kg
            </div>
          </div>
        </div>
      </div>

      <div class="space-y-1">
        <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Resources</h3>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <% active = Map.get(totals, :calories_burned_active) %>
          <% resting = Map.get(totals, :calories_burned_resting) %>
          <% total = Map.get(totals, :calories_burned_total) %>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Calories carried</div>
            <div class="text-lg font-semibold tabular-nums">{calories} kcal</div>
            <%= if total do %>
              <% diff = calories - total %>
              <div class="text-xs opacity-50">
                <%= if diff >= 0 do %>
                  +{diff} kcal surplus
                <% else %>
                  {diff} kcal deficit
                <% end %>
              </div>
            <% else %>
              <div :if={days} class="text-xs opacity-50">
                ~{div(calories, max(days, 1))} kcal/day
              </div>
            <% end %>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Burn (active)</div>
            <%= if active do %>
              <div class="text-lg font-semibold tabular-nums">{active} kcal</div>
              <div class="text-xs opacity-50">while walking</div>
            <% else %>
              <div class="text-base opacity-50 italic">needs legs + leader weight</div>
            <% end %>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Burn (resting)</div>
            <%= if resting do %>
              <div class="text-lg font-semibold tabular-nums">{resting} kcal</div>
              <div class="text-xs opacity-50">camp/sleep BMR</div>
            <% else %>
              <div class="text-base opacity-50 italic">needs dates + leader weight</div>
            <% end %>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Power</div>
            <div class="text-lg font-semibold tabular-nums">{Map.get(totals, :power_mah, 0)} mAh</div>
          </div>
        </div>
      </div>
    </div>

    <div
      :if={report.errors != [] or report.warnings != []}
      class="grid grid-cols-1 lg:grid-cols-2 gap-2 mt-3"
    >
      <div :if={report.errors != []} class="card bg-error/10 border border-error p-3">
        <div class="text-xs font-semibold uppercase tracking-wide text-error mb-1">Errors</div>
        <ul class="list-disc pl-5 text-sm text-error space-y-0.5">
          <li :for={e <- report.errors}>
            {e.item_title}: missing charger
          </li>
        </ul>
      </div>
      <div :if={report.warnings != []} class="card bg-warning/10 border border-warning p-3">
        <div class="text-xs font-semibold uppercase tracking-wide text-warning mb-1">Warnings</div>
        <ul class="list-disc pl-5 text-sm text-warning space-y-0.5">
          <li :for={w <- report.warnings}>
            {w.item_title}: no spare battery on trip
          </li>
        </ul>
      </div>
    </div>

    <div class="flex justify-between items-center mt-6">
      <h2 class="text-lg font-semibold">Items on this trip</h2>
      <button phx-click="open_picker" class="btn btn-primary btn-sm">+ Add items</button>
    </div>

    <%= if @trip.trip_items == [] do %>
      <p class="opacity-70 italic mt-2">No items added yet — click "Add items" above.</p>
    <% else %>
      <div class="space-y-6 mt-2">
        <section :for={{cat, label} <- @visible_categories}>
          <div class="flex justify-between items-baseline border-b border-success pb-0.5 mb-1">
            <h3 class="text-success text-xs font-bold uppercase tracking-wide">{label}</h3>
            <span class="text-success text-xs tabular-nums opacity-80">
              <span :if={cap = @section_capacity.(cat)} class="mr-2">Σ {format_capacity(cap)}L</span><span
                :if={kcal = @section_calories.(cat)}
                class="mr-2"
              >Σ {kcal}kcal<span :if={cat == :food && kcal_per_g}> · avg {kcal_per_g} kcal/g</span></span>{@section_weight.(
                cat
              )}g
            </span>
          </div>
          <ul class="divide-y divide-base-300">
            <li
              :for={ti <- Map.get(@grouped, cat, [])}
              class="flex flex-wrap sm:flex-nowrap items-center py-2 px-0.5 sm:px-1 gap-x-2 gap-y-1"
            >
              <span class="basis-full sm:basis-auto sm:flex-1 min-w-0 sm:truncate text-sm">
                <span
                  :if={ti.item.brand}
                  class="opacity-60 mr-1"
                >{ti.item.brand}</span>{ti.item.title}
                <span :if={ti.source == :kit} class="badge badge-xs ml-1">kit</span>
              </span>
              <span
                :if={cap = pack_capacity(ti)}
                class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap"
              >
                {format_capacity(cap)}L
              </span>
              <span
                :if={kcal = food_calories(ti)}
                class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap"
              >
                {kcal}kcal
              </span>
              <span class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                <%= if ti.qty > 1 do %>
                  {ti.item.weight_g || 0}g×{ti.qty}
                <% else %>
                  ×1
                <% end %>
              </span>
              <span class="opacity-60 text-xs tabular-nums w-14 sm:w-16 text-right">
                {(ti.item.weight_g || 0) * ti.qty}g
              </span>
              <span class="badge badge-ghost badge-sm whitespace-nowrap">
                {carry_mode_label(ti.carry_mode)}
              </span>
              <button
                phx-click="remove_item"
                phx-value-id={ti.id}
                data-confirm="Remove from trip?"
                class="btn btn-ghost btn-xs"
              >
                ×
              </button>
            </li>
          </ul>
        </section>
      </div>
    <% end %>

    <form phx-submit="add_kit" class="card bg-base-200 p-4 flex flex-col gap-2 mt-4 max-w-md">
      <h3 class="font-semibold">Or add a whole kit</h3>
      <select name="kit_id" class="select select-bordered">
        <option value="">Pick a kit…</option>
        <option :for={k <- @kits} value={k.id}>{k.name}</option>
      </select>
      <button class="btn btn-primary">Expand kit into items</button>
    </form>

    <%= if @trip.state == :draft do %>
      <button phx-click="start_packing" class="btn btn-warning mt-4">Start packing →</button>
    <% end %>
    """
  end

  # `weight_breakdown`, `food_calories`, `pack_capacity`, and
  # `format_capacity` are public so PackheavyWeb.PublicTripLive can
  # render the same summary widgets without duplicating logic.

  attr :trip, :any, required: true

  def weight_breakdown(assigns) do
    ~H"""
    <% report = @trip.validation_report || %{totals: %{}} %>
    <% totals = report.totals || %{} %>
    <% dry_g = Map.get(totals, :weight_g, 0) %>
    <% food_g = Map.get(totals, :food_weight_g, 0) %>
    <% water_g = Map.get(totals, :water_weight_g, 0) %>
    <% base_g = dry_g - food_g %>
    <% days = PackheavyWeb.TripLive.Show.trip_days(@trip) %>

    <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
      <div class="summary-card card bg-base-200 p-3">
        <div class="text-xs opacity-70">Base</div>
        <div class="text-lg font-semibold tabular-nums">{base_g} g</div>
        <div class="text-xs opacity-50">empty containers + gear</div>
      </div>
      <div class="summary-card card bg-base-200 p-3">
        <div class="text-xs opacity-70">Base + food</div>
        <div class="text-lg font-semibold tabular-nums">{dry_g} g</div>
        <div class="text-xs opacity-50">+ {food_g} g food</div>
        <div :if={days && food_g > 0} class="text-xs opacity-50">
          ~{div(food_g, max(days, 1))} g/day · {days} day(s)
        </div>
      </div>
      <div class="summary-card card bg-base-200 p-3">
        <div class="text-xs opacity-70">Base + food + water</div>
        <div class="text-lg font-semibold tabular-nums">{dry_g + water_g} g</div>
        <div class="text-xs opacity-50">+ {water_g} g water (full)</div>
      </div>
    </div>
    """
  end

  def food_calories(ti) do
    case ti.item && ti.item.category_data do
      %Ash.Union{value: %Packheavy.Inventory.Item.Food{calories: c}} when is_integer(c) ->
        c

      _ ->
        nil
    end
  end

  def pack_capacity(ti) do
    case ti.item && ti.item.category_data do
      %Ash.Union{value: %Packheavy.Inventory.Item.Pack{volume_l: v}} when is_number(v) ->
        v

      _ ->
        nil
    end
  end

  def carry_mode_label(:worn), do: "Worn"
  def carry_mode_label(:day_pack), do: "Day pack"
  def carry_mode_label(:main_pack), do: "Main pack"
  def carry_mode_label(nil), do: "Main pack"

  def format_capacity(v) when is_float(v) do
    if v == Float.round(v),
      do: Integer.to_string(trunc(v)),
      else: :erlang.float_to_binary(v, decimals: 1)
  end

  def format_capacity(v), do: to_string(v)

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
      {:first_aid, "First aid"},
      {:hygiene, "Hygiene"},
      {:containers, "Containers"},
      {:tools, "Tools"},
      {:other, "Other"}
    ]
  end

  attr :trip, :any, required: true
  attr :rechargeable_battery_ids, :any, required: true

  defp pack_tab(assigns) do
    grouped =
      assigns.trip.trip_items
      |> Enum.sort_by(fn ti ->
        item = ti.item
        String.downcase("#{(item && item.brand) || ""} #{item && item.title}")
      end)
      |> Enum.group_by(fn ti ->
        case ti.item && ti.item.category_data do
          %Ash.Union{type: t} -> t
          _ -> :other
        end
      end)

    visible_categories =
      Enum.filter(category_order(), fn {cat, _} -> Map.has_key?(grouped, cat) end)

    section_progress = fn cat ->
      tis = Map.get(grouped, cat, [])
      packed = Enum.count(tis, & &1.packed)
      {packed, length(tis)}
    end

    assigns =
      assigns
      |> assign(:grouped, grouped)
      |> assign(:visible_categories, visible_categories)
      |> assign(:section_progress, section_progress)

    ~H"""
    <%= if @trip.state == :draft do %>
      <p class="opacity-70 mt-2">Move the trip into packing mode first (from the Plan tab).</p>
    <% else %>
      <div class="space-y-6 mt-2">
        <section :for={{cat, label} <- @visible_categories}>
          <% {packed, total} = @section_progress.(cat) %>
          <div class="flex justify-between items-baseline border-b border-success pb-0.5 mb-1">
            <h3 class="text-success text-xs font-bold uppercase tracking-wide">{label}</h3>
            <span class={[
              "text-xs tabular-nums opacity-80",
              packed == total && "text-success",
              packed != total && "text-warning"
            ]}>
              {packed}/{total} packed
            </span>
          </div>
          <div class="flex items-center gap-2 px-1 pb-1 text-[10px] uppercase tracking-wide opacity-60">
            <span class="flex-1"></span>
            <span class="flex items-center justify-end gap-1 w-12 sm:w-24 shrink-0" aria-hidden="true">
              <.icon name="hero-bolt-mini" class="size-3" /><span class="hidden sm:inline">
                charged
              </span>
            </span>
            <span class="flex items-center justify-end gap-1 w-12 sm:w-24 shrink-0" aria-hidden="true">
              <.icon name="hero-check-circle-mini" class="size-3" /><span class="hidden sm:inline">
                tested
              </span>
            </span>
            <span class="flex items-center justify-end gap-1 w-12 sm:w-24 shrink-0" aria-hidden="true">
              <.icon name="hero-archive-box-mini" class="size-3" /><span class="hidden sm:inline">
                packed
              </span>
            </span>
          </div>
          <ul class="divide-y divide-base-300">
            <li
              :for={ti <- Map.get(@grouped, cat, [])}
              class="flex flex-wrap sm:flex-nowrap items-center py-2 px-0.5 sm:px-1 gap-x-2 gap-y-1"
            >
              <span class="basis-full sm:basis-auto sm:flex-1 min-w-0 sm:truncate text-sm">
                <span
                  :if={ti.item.brand}
                  class="opacity-60 mr-1"
                >{ti.item.brand}</span>{ti.item.title}
              </span>
              <span class="text-xs opacity-60 shrink-0 tabular-nums whitespace-nowrap ml-auto sm:ml-0">
                <%= if ti.qty > 1 do %>
                  {ti.item.weight_g || 0}g×{ti.qty}
                <% else %>
                  ×1
                <% end %>
              </span>
              <span :if={ti.source == :kit} class="badge badge-xs shrink-0">kit</span>
              <%= if PackheavyWeb.TripLive.Show.needs_charging?(ti, @rechargeable_battery_ids) do %>
                <label
                  class="flex items-center justify-end cursor-pointer w-12 sm:w-24 shrink-0"
                  aria-label="charged"
                >
                  <input
                    type="checkbox"
                    class="checkbox md:checkbox-lg print:hidden"
                    checked={ti.charged}
                    phx-click="toggle_charged"
                    phx-value-id={ti.id}
                  />
                  <span class="hidden print:inline text-base leading-none">
                    {if ti.charged, do: "☑", else: "☐"}
                  </span>
                </label>
              <% else %>
                <span class="w-12 sm:w-24 shrink-0 text-right opacity-20">—</span>
              <% end %>
              <label
                class="flex items-center justify-end cursor-pointer w-12 sm:w-24 shrink-0"
                aria-label="tested"
              >
                <input
                  type="checkbox"
                  class="checkbox md:checkbox-lg print:hidden"
                  checked={ti.tested}
                  phx-click="toggle_tested"
                  phx-value-id={ti.id}
                />
                <span class="hidden print:inline text-base leading-none">
                  {if ti.tested, do: "☑", else: "☐"}
                </span>
              </label>
              <label
                class="flex items-center justify-end cursor-pointer w-12 sm:w-24 shrink-0"
                aria-label="packed"
              >
                <input
                  type="checkbox"
                  class="checkbox md:checkbox-lg print:hidden"
                  checked={ti.packed}
                  phx-click="toggle_packed"
                  phx-value-id={ti.id}
                />
                <span class="hidden print:inline text-base leading-none">
                  {if ti.packed, do: "☑", else: "☐"}
                </span>
              </label>
            </li>
          </ul>
        </section>
      </div>
    <% end %>
    """
  end

  attr :trip, :any, required: true

  defp complete_tab(assigns) do
    ~H"""
    <%= cond do %>
      <% @trip.state == :complete -> %>
        <p class="text-success mt-2">This trip is complete. Food qty has been decremented.</p>
      <% @trip.state == :packing -> %>
        <p class="opacity-70 mt-2">Marking complete will decrement food item qty by what you took.</p>
        <button
          phx-click="complete"
          data-confirm="Complete trip and decrement food?"
          class="btn btn-success mt-2"
        >
          Complete trip
        </button>
      <% true -> %>
        <p class="opacity-70 mt-2">Move the trip through Plan → Pack first.</p>
    <% end %>
    """
  end

  # ---- Route tab ----------------------------------------------------------

  attr :trip, :any, required: true
  attr :uploads, :any, required: true
  attr :leg_modal, :any, default: nil

  defp route_tab(assigns) do
    palette = leg_palette()

    legs_with_color =
      assigns.trip.trip_legs
      |> Enum.with_index()
      |> Enum.map(fn {leg, idx} ->
        Map.put(leg, :color, Enum.at(palette, rem(idx, length(palette))))
      end)

    total_distance = legs_with_color |> Enum.map(& &1.distance_m) |> Enum.sum()
    total_gain = legs_with_color |> Enum.map(& &1.elevation_gain_m) |> Enum.sum()
    legs_count = length(legs_with_color)
    last_index = legs_count - 1

    # Inputs to the per-leg calorie estimate. Calorie display is
    # suppressed if either is missing — pace + time still works.
    leader_kg = Packheavy.Trips.Helpers.leader_weight_kg(assigns.trip)
    loads = Packheavy.Trips.Helpers.pack_loads(assigns.trip)

    total_time_h = Packheavy.Trips.Helpers.trip_time_h(assigns.trip)
    active_calories = Packheavy.Trips.Helpers.trip_calories(assigns.trip, leader_kg, loads)
    resting_calories = Packheavy.Trips.Helpers.trip_resting_calories(assigns.trip, leader_kg)

    legs_by_day_map =
      legs_with_color
      |> Enum.group_by(& &1.day)
      |> Map.new(fn {day, legs} -> {day, Enum.sort_by(legs, & &1.position)} end)

    # Day count is derived from the trip's start/end dates so sections
    # exist before any legs are uploaded. Falls back to the highest
    # leg.day when dates are absent (or when a leg has been pushed past
    # the date range, e.g. dates were set later).
    date_days = trip_days(assigns.trip) || 0
    leg_max_day = legs_by_day_map |> Map.keys() |> Enum.max(fn -> 0 end)
    days_to_show = max(date_days, leg_max_day) |> max(1)

    days_with_legs =
      Enum.map(1..days_to_show, fn day ->
        {day, Map.get(legs_by_day_map, day, [])}
      end)

    legs_by_day = days_with_legs

    legs_payload_json = assigns.trip |> build_legs_payload() |> Jason.encode!()

    assigns =
      assigns
      |> assign(:legs_with_color, legs_with_color)
      |> assign(:legs_by_day, legs_by_day)
      |> assign(:days_to_show, days_to_show)
      |> assign(:total_distance, total_distance)
      |> assign(:total_gain, total_gain)
      |> assign(:legs_count, legs_count)
      |> assign(:last_index, last_index)
      |> assign(:legs_payload_json, legs_payload_json)
      |> assign(:leader_kg, leader_kg)
      |> assign(:loads, loads)
      |> assign(:total_time_h, total_time_h)
      |> assign(:active_calories, active_calories)
      |> assign(:resting_calories, resting_calories)

    ~H"""
    <div class="space-y-4 mt-4">
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Total distance</div>
          <div class="text-3xl font-bold">
            {:erlang.float_to_binary(@total_distance / 1000, decimals: 2)} km
          </div>
          <div class="text-xs opacity-60">
            {@legs_count} leg{if @legs_count == 1, do: "", else: "s"}
          </div>
        </div>
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Total elevation gain</div>
          <div class="text-3xl font-bold">{round(@total_gain)} m</div>
        </div>
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Estimated time</div>
          <div class="text-3xl font-bold">
            {if @total_time_h, do: Packheavy.Trips.Helpers.format_hours(@total_time_h), else: "—"}
          </div>
          <div class="text-xs opacity-60">Adjust pace per leg below.</div>
        </div>
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Burn (active)</div>
          <div class="text-3xl font-bold">
            {if @active_calories, do: "#{@active_calories} kcal", else: "—"}
          </div>
          <div :if={!@active_calories} class="text-xs opacity-60">
            Needs leader weight + items to estimate.
          </div>
          <div :if={@active_calories} class="text-xs opacity-60">while walking</div>
        </div>
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Burn (resting)</div>
          <div class="text-3xl font-bold">
            {if @resting_calories, do: "#{@resting_calories} kcal", else: "—"}
          </div>
          <div :if={!@resting_calories} class="text-xs opacity-60">
            Needs trip dates + leader weight.
          </div>
          <div :if={@resting_calories} class="text-xs opacity-60">camp/sleep BMR</div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_minmax(420px,640px)] gap-4">
        <div
          :if={@legs_count > 0}
          id="trip-route-map"
          phx-hook="RouteMap"
          phx-update="ignore"
          data-legs={@legs_payload_json}
          class="w-full h-[500px] lg:h-[760px] lg:sticky lg:top-4 rounded order-first lg:order-none"
        >
        </div>

        <div class="space-y-4 lg:max-h-[760px] lg:overflow-y-auto lg:pr-1">
          <div :for={{day, day_legs} <- @legs_by_day} class="space-y-2">
            <div class="flex items-baseline gap-3 flex-wrap">
              <h3 class="text-sm font-bold uppercase tracking-wide opacity-80">
                Day {day}<span
                  :if={date = day_date(@trip, day)}
                  class="opacity-60 font-normal normal-case ml-2"
                >{date}</span>
              </h3>
              <span :if={day_legs != []} class="text-xs opacity-60 tabular-nums">
                {day_summary(day_legs)}
              </span>
              <span
                :if={sun = Packheavy.Trips.Helpers.day_sun(@trip, day)}
                class="text-xs opacity-60 tabular-nums"
              >
                ☀ {Packheavy.Trips.Helpers.format_clock(sun.sunrise)}–{Packheavy.Trips.Helpers.format_clock(
                  sun.sunset
                )} · {Packheavy.Trips.Helpers.format_hours(sun.daylight_h)} daylight
              </span>
              <span :if={day_legs == []} class="text-xs opacity-50 italic">no legs yet</span>
              <button
                type="button"
                phx-click="open-add-leg"
                phx-value-day={day}
                class="btn btn-ghost btn-xs ml-auto"
              >
                + Add leg
              </button>
            </div>

            <div
              :for={{leg, day_idx} <- Enum.with_index(day_legs)}
              class="card bg-base-200 p-4 space-y-2"
            >
              <div class="flex items-start gap-2">
                <span
                  class="inline-block w-3 h-3 rounded-sm shrink-0 mt-1.5"
                  style={"background-color: #{leg.color}"}
                >
                </span>
                <div class="flex-1 min-w-0">
                  <div class="font-semibold break-words">
                    {leg.name}
                    <span :if={leg.sidequest} class="badge badge-xs badge-info ml-1 align-middle">
                      sidequest
                    </span>
                  </div>
                  <div class="text-xs opacity-70 tabular-nums mt-0.5">
                    {:erlang.float_to_binary(leg.distance_m / 1000, decimals: 2)} km · +{round(
                      leg.elevation_gain_m
                    )} m · {Packheavy.Trips.Helpers.format_hours(
                      Packheavy.Trips.Helpers.leg_time_h(leg)
                    )}
                    <%= if leg_calories = Packheavy.Trips.Helpers.leg_calories(leg, @leader_kg, @loads) do %>
                      · {leg_calories} kcal
                    <% end %>
                  </div>
                </div>
                <div class="flex items-center gap-1 shrink-0">
                  <button
                    type="button"
                    phx-click="fly-to-leg"
                    phx-value-id={leg.id}
                    class="btn btn-ghost btn-xs gap-1"
                    title="Show this leg on the map"
                  >
                    <.icon name="hero-map-mini" class="size-3" /> Map
                  </button>
                  <button
                    type="button"
                    phx-click="move-leg"
                    phx-value-id={leg.id}
                    phx-value-dir="up"
                    class="btn btn-ghost btn-xs"
                    disabled={day_idx == 0}
                    title="Move up within day"
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    phx-click="move-leg"
                    phx-value-id={leg.id}
                    phx-value-dir="down"
                    class="btn btn-ghost btn-xs"
                    disabled={day_idx == length(day_legs) - 1}
                    title="Move down within day"
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    phx-click="open-edit-leg"
                    phx-value-id={leg.id}
                    class="btn btn-ghost btn-xs"
                    title="Edit name, day, sidequest, pace"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    phx-click="delete-leg"
                    phx-value-id={leg.id}
                    data-confirm={"Remove leg \"#{leg.name}\"?"}
                    class="btn btn-ghost btn-xs text-error"
                    title="Delete"
                  >
                    ×
                  </button>
                </div>
              </div>

              <%= if leg_has_elevation?(leg) do %>
                <div
                  id={"leg-chart-#{leg.id}"}
                  phx-hook="LegChart"
                  phx-update="ignore"
                  data-leg-id={leg.id}
                  data-color={leg.color}
                  data-track={Jason.encode!(Packheavy.Trips.Helpers.slim_track_for_chart(leg.track))}
                >
                  {Phoenix.HTML.raw(leg_elevation_svg(leg))}
                </div>
              <% else %>
                <p class="text-sm opacity-70">No elevation data in this GPX.</p>
              <% end %>
              <div
                :if={leg.notes && leg.notes != ""}
                class="markdown text-sm opacity-90 border-l-2 border-base-300 pl-3 ml-5"
              >
                {PackheavyWeb.Markdown.render(leg.notes)}
              </div>
            </div>
          </div>
        </div>
      </div>

      <.leg_modal :if={@leg_modal} state={@leg_modal} uploads={@uploads} days_to_show={@days_to_show} />
    </div>
    """
  end

  defp leg_has_elevation?(%{track: track}),
    do: Enum.any?(track, &(Map.get(&1, :ele) || Map.get(&1, "ele")))

  attr :state, :map, required: true
  attr :uploads, :any, required: true
  attr :days_to_show, :integer, required: true

  defp leg_modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      phx-window-keydown="close-leg-modal"
      phx-key="escape"
    >
      <div class="modal-box max-w-lg">
        <%= case @state do %>
          <% %{mode: :add, day: day} -> %>
            <h3 class="font-bold text-lg mb-3">Add leg to Day {day}</h3>
            <form phx-change="validate-leg" phx-submit="add-leg" class="space-y-3">
              <input type="hidden" name="day" value={day} />
              <label class="flex flex-col gap-1">
                <span class="text-xs opacity-70">GPX file</span>
                <.live_file_input
                  upload={@uploads.leg_gpx}
                  class="file-input file-input-bordered w-full"
                />
              </label>
              <div :for={entry <- @uploads.leg_gpx.entries} class="text-sm flex items-center gap-2">
                <span>{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel-leg-upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-xs"
                >
                  Remove
                </button>
              </div>
              <div :for={err <- upload_errors(@uploads.leg_gpx)} class="text-error text-sm">
                {Phoenix.Naming.humanize(err)}
              </div>
              <label class="flex flex-col gap-1">
                <span class="text-xs opacity-70">Name (defaults to filename)</span>
                <input
                  type="text"
                  name="name"
                  placeholder="e.g. Cradle to Waterfall Valley"
                  class="input input-bordered input-sm w-full"
                />
              </label>
              <div class="grid grid-cols-2 gap-3">
                <label class="flex flex-col gap-1">
                  <span class="text-xs opacity-70">Pace (km/h)</span>
                  <input
                    type="number"
                    name="pace_kmh"
                    step="0.1"
                    min="1"
                    max="10"
                    value="4.0"
                    class="input input-bordered input-sm w-full tabular-nums"
                  />
                </label>
                <label class="flex items-end gap-2 mb-1">
                  <input type="checkbox" name="sidequest" value="true" class="checkbox checkbox-sm" />
                  <span class="text-sm">Sidequest (day pack only)</span>
                </label>
              </div>
              <label class="flex flex-col gap-1">
                <span class="text-xs opacity-70">Notes (optional, Markdown)</span>
                <textarea
                  name="notes"
                  rows="4"
                  class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
                  placeholder="Water at km 8, river crossing at km 12, scrambly final 200m..."
                ></textarea>
              </label>
              <div class="flex justify-end gap-2 mt-2">
                <button type="button" phx-click="close-leg-modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  disabled={@uploads.leg_gpx.entries == []}
                >
                  Add leg
                </button>
              </div>
            </form>
          <% %{mode: :edit, leg: leg} -> %>
            <h3 class="font-bold text-lg mb-3">Edit leg</h3>
            <form phx-submit="save-leg-edit" class="space-y-3">
              <input type="hidden" name="leg_id" value={leg.id} />
              <label class="flex flex-col gap-1">
                <span class="text-xs opacity-70">Name</span>
                <input
                  type="text"
                  name="name"
                  value={leg.name}
                  class="input input-bordered input-sm w-full"
                />
              </label>
              <div class="grid grid-cols-3 gap-3">
                <label class="flex flex-col gap-1">
                  <span class="text-xs opacity-70">Day</span>
                  <select name="day" class="select select-bordered select-sm w-full">
                    <option :for={n <- 1..@days_to_show} value={n} selected={n == leg.day}>
                      Day {n}
                    </option>
                  </select>
                </label>
                <label class="flex flex-col gap-1">
                  <span class="text-xs opacity-70">Pace (km/h)</span>
                  <input
                    type="number"
                    name="pace_kmh"
                    step="0.1"
                    min="1"
                    max="10"
                    value={leg.pace_kmh}
                    class="input input-bordered input-sm w-full tabular-nums"
                  />
                </label>
                <label class="flex items-end gap-2 mb-1">
                  <input
                    type="checkbox"
                    name="sidequest"
                    value="true"
                    checked={leg.sidequest}
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-sm">Sidequest</span>
                </label>
              </div>
              <p class="text-xs opacity-60">
                Sidequest legs only count worn + day-pack weight toward the carry load.
              </p>
              <label class="flex flex-col gap-1">
                <span class="text-xs opacity-70">Notes (optional, Markdown)</span>
                <textarea
                  name="notes"
                  rows="4"
                  class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
                  placeholder="Water at km 8, river crossing at km 12, scrambly final 200m..."
                >{leg.notes}</textarea>
              </label>
              <div class="flex justify-end gap-2 mt-2">
                <button type="button" phx-click="close-leg-modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Save</button>
              </div>
            </form>
        <% end %>
      </div>
      <button
        type="button"
        phx-click="close-leg-modal"
        class="modal-backdrop"
        aria-label="Close"
      >
      </button>
    </div>
    """
  end

  defp day_date(%{start_date: %Date{} = sd}, day) when is_integer(day) and day >= 1 do
    sd |> Date.add(day - 1) |> Calendar.strftime("%a %d %b")
  end

  defp day_date(_, _), do: nil

  defp day_summary(legs) do
    distance_km =
      legs |> Enum.map(& &1.distance_m) |> Enum.sum() |> Kernel./(1000.0)

    time_h =
      Enum.reduce(legs, 0.0, fn leg, acc ->
        acc + (Packheavy.Trips.Helpers.leg_time_h(leg) || 0.0)
      end)

    "#{:erlang.float_to_binary(distance_km, decimals: 1)} km · #{Packheavy.Trips.Helpers.format_hours(time_h)}"
  end

  # Server-rendered SVG line chart for one leg. Same coordinate scheme
  # as the .LegChart hook (viewBox 800x200) so the JS-injected
  # crosshair lines up.
  defp leg_elevation_svg(%{track: track, color: color, id: _id}) do
    samples = elevation_samples(track)

    case samples do
      [] ->
        ""

      [_only] ->
        ""

      _ ->
        {min_e, max_e} = samples |> Enum.map(& &1.ele) |> Enum.min_max()
        # Floor the y-axis range at 100 m so flat legs don't visually
        # exaggerate noise (a 5 m wobble across a 16 km flat leg
        # otherwise fills the whole chart and reads as wild terrain).
        # Pad symmetrically around the data midpoint when the natural
        # range is below the floor.
        min_span = 100.0
        data_span = max_e - min_e

        {view_min, view_max} =
          if data_span < min_span do
            pad = (min_span - data_span) / 2.0
            {min_e - pad, max_e + pad}
          else
            {min_e, max_e}
          end

        total_d = samples |> List.last() |> Map.get(:d) |> max(1.0)
        e_span = max(view_max - view_min, 1.0)

        plotted =
          Enum.map(samples, fn s ->
            x = s.d / total_d * 800
            y = 200 - (s.ele - view_min) / e_span * 180 - 10
            Map.merge(s, %{x: x, y: y})
          end)

        # One trapezoid per consecutive pair, fill keyed by absolute
        # incline % so steep sections show in red, mild in green.
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
        <svg viewBox="0 0 800 200" class="w-full h-40 select-none" style="color: #{color}">
          #{segments_svg}
          <polyline points="#{polyline_str}" fill="none" stroke="currentColor" stroke-width="1.5" />
          <text x="4" y="14" class="fill-base-content text-xs opacity-70">#{round(view_max)} m</text>
          <text x="4" y="196" class="fill-base-content text-xs opacity-70">#{round(view_min)} m</text>
          <text x="796" y="196" text-anchor="end" class="fill-base-content text-xs opacity-70">#{:erlang.float_to_binary(total_d / 1000, decimals: 1)} km</text>
        </svg>
        """
    end
  end

  # Helpers for the gradient-coloured elevation chart.
  defp elevation_samples(track) do
    track
    |> Enum.filter(&(track_field(&1, :ele) != nil))
    |> Enum.map(fn pt -> %{d: track_field(pt, :d), ele: track_field(pt, :ele)} end)
  end

  defp signed_slope_pct(%{d: d1, ele: e1}, %{d: d2, ele: e2}) do
    dh = d2 - d1
    if dh > 0, do: (e2 - e1) / dh * 100, else: 0.0
  end

  # Colour buckets, matching Komoot's scheme. Uphill bands kick in
  # earlier than downhill bands because climbing costs more energy
  # than descending — a 5 % uphill is a noticeable grunt while a
  # 5 % downhill barely registers.
  #
  # Uphill   |    0–5 % green | 5–15 % yellow | 15–20 % orange-red | 20 %+ dark red
  # Downhill | 0 to -10 green | -10 to -15 y  | -15 to -20 or-red  | -20 %+ dark red
  defp incline_color(slope) do
    cond do
      slope >= 20.0 -> "rgba(153,27,27,0.55)"
      slope >= 15.0 -> "rgba(234,88,12,0.5)"
      slope >= 5.0 -> "rgba(250,204,21,0.45)"
      slope <= -20.0 -> "rgba(153,27,27,0.55)"
      slope <= -15.0 -> "rgba(234,88,12,0.5)"
      slope <= -10.0 -> "rgba(250,204,21,0.45)"
      true -> "rgba(74,222,128,0.4)"
    end
  end

  defp fmt(n), do: :erlang.float_to_binary(n / 1.0, decimals: 1)

  # Track entries come back from Postgres as string-keyed maps, but
  # are atom-keyed when the LiveView creates them in the same request.
  # Tolerant lookup keeps both code paths working.
  defp track_field(%{} = m, key) when is_atom(key),
    do: Map.get(m, key) || Map.get(m, Atom.to_string(key))
end
