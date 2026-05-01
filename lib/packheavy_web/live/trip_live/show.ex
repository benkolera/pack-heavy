defmodule PackheavyWeb.TripLive.Show do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Trips

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    rechargeable_battery_ids =
      Inventory.list_battery_types!(actor: user)
      |> Enum.filter(& &1.rechargeable)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:ok,
     socket
     |> assign(:trip_id, id)
     |> assign(:tab, :plan)
     |> assign(:items, Inventory.list_items!(actor: user))
     |> assign(:kits, Inventory.list_kits!(actor: user))
     |> assign(:rechargeable_battery_ids, rechargeable_battery_ids)
     |> assign(:picker_open, false)
     |> reload()}
  end

  defp existing_qty_on_trip(trip) do
    trip.trip_items
    |> Enum.group_by(& &1.item_id, & &1.qty)
    |> Map.new(fn {iid, qtys} -> {iid, Enum.sum(qtys)} end)
  end

  defp max_qty_for_trip(items) do
    Map.new(items, fn item -> {item.id, item.qty || 0} end)
  end

  defp reload(socket) do
    user = socket.assigns.current_user

    trip =
      Ash.get!(Packheavy.Trips.Trip, socket.assigns.trip_id,
        actor: user,
        load: [:validation_report, trip_items: [:item], trip_kits: [:kit]]
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

  def handle_event("complete", _, socket) do
    socket.assigns.trip
    |> Ash.Changeset.for_update(:complete)
    |> Ash.update!(actor: socket.assigns.current_user)

    {:noreply,
     socket |> put_flash(:info, "Trip complete. Food qty decremented.") |> reload()}
  end

  @impl true
  def handle_info({:item_picker_confirm, "trip-item-picker", selected}, socket) do
    user = socket.assigns.current_user
    trip_id = socket.assigns.trip_id

    existing_by_item =
      socket.assigns.trip.trip_items
      |> Enum.group_by(& &1.item_id)

    item_ids = MapSet.union(MapSet.new(Map.keys(selected)), MapSet.new(Map.keys(existing_by_item)))

    Enum.each(item_ids, fn item_id ->
      desired = Map.get(selected, item_id, 0)
      existing_rows = Map.get(existing_by_item, item_id, [])
      current = Enum.map(existing_rows, & &1.qty) |> Enum.sum()

      cond do
        desired == current ->
          :ok

        desired == 0 ->
          Enum.each(existing_rows, &Ash.destroy!(&1, actor: user))

        true ->
          # Replace all existing TripItems for this item with one :direct entry
          # at the desired qty. (Loses kit-source attribution, fine for v1.)
          Enum.each(existing_rows, &Ash.destroy!(&1, actor: user))

          Trips.add_trip_item!(
            %{trip_id: trip_id, item_id: item_id, qty: desired, source: :direct},
            actor: user
          )
      end
    end)

    {:noreply,
     socket
     |> assign(:picker_open, false)
     |> put_flash(:info, "Trip items updated.")
     |> reload()}
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

      <div role="tablist" class="tabs tabs-boxed">
        <a role="tab" class={["tab", @tab == :plan && "tab-active"]} phx-click="set_tab" phx-value-tab="plan">Plan</a>
        <a role="tab" class={["tab", @tab == :pack && "tab-active"]} phx-click="set_tab" phx-value-tab="pack">Pack</a>
        <a role="tab" class={["tab", @tab == :complete && "tab-active"]} phx-click="set_tab" phx-value-tab="complete">Complete</a>
      </div>

      <%= case @tab do %>
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
          existing_qty={existing_qty_on_trip(@trip)}
          max_qty_for={max_qty_for_trip(@items)}
          title={"Items on " <> @trip.name}
          confirm_label="Save"
          close_event="close_picker"
        />
      <% end %>
    </Layouts.app>
    """
  end

  attr :trip, :any, required: true
  attr :socket, :any, required: true

  defp share_panel(assigns) do
    share_url =
      if assigns.trip.share_token do
        url(assigns.socket, ~p"/share/trip/#{assigns.trip.share_token}")
      end

    assigns = assign(assigns, :share_url, share_url)

    ~H"""
    <div class="flex items-center gap-1 text-sm print:hidden">
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

    <div class="grid grid-cols-1 xl:grid-cols-2 print:grid-cols-1 gap-4 mt-2">
      <div class="space-y-1">
        <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Weight breakdown</h3>
        <.weight_breakdown trip={@trip} />
      </div>

      <div class="space-y-1">
        <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Resources</h3>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Calories</div>
            <div class="text-lg font-semibold tabular-nums">{calories} kcal</div>
            <div :if={days} class="text-xs opacity-50">
              ~{div(calories, max(days, 1))} kcal/day · {days} day(s)
            </div>
            <div :if={kcal_per_g} class="text-xs opacity-50">
              avg {kcal_per_g} kcal/g across {food_g} g
            </div>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Carrying capacity</div>
            <div class="text-lg font-semibold tabular-nums">{format_capacity(Map.get(totals, :pack_volume_l, 0))} L</div>
            <div class="text-xs opacity-50">
              + {Map.get(totals, :water_ml, 0)} ml water
            </div>
          </div>
          <div class="summary-card card bg-base-200 p-3">
            <div class="text-xs opacity-70">Power</div>
            <div class="text-lg font-semibold tabular-nums">{Map.get(totals, :power_mah, 0)} mAh</div>
          </div>
        </div>
      </div>
    </div>

    <div :if={report.errors != [] or report.warnings != []} class="grid grid-cols-1 lg:grid-cols-2 gap-2 mt-3">
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
              <span :if={cap = @section_capacity.(cat)} class="mr-2">Σ {format_capacity(cap)} L</span><span :if={kcal = @section_calories.(cat)} class="mr-2">Σ {kcal} kcal</span>{@section_weight.(cat)} g
            </span>
          </div>
          <ul class="divide-y divide-base-300">
            <li :for={ti <- Map.get(@grouped, cat, [])} class="flex items-center py-2 px-1 gap-2">
              <span class="flex-1 min-w-0 truncate text-sm">
                <span :if={ti.item.brand} class="opacity-60 mr-1 inline-block max-w-[7rem] sm:max-w-none truncate align-bottom">{ti.item.brand}</span>{ti.item.title}
                <span :if={ti.source == :kit} class="badge badge-xs ml-1">kit</span>
              </span>
              <span :if={cap = pack_capacity(ti)} class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">{format_capacity(cap)} L</span>
              <span :if={kcal = food_calories(ti)} class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">{kcal} kcal</span>
              <span class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                <%= if ti.qty > 1 do %>
                  {ti.item.weight_g || 0} g × {ti.qty}
                <% else %>
                  ×1
                <% end %>
              </span>
              <span class="opacity-60 text-xs tabular-nums w-16 text-right">{(ti.item.weight_g || 0) * ti.qty} g</span>
              <button phx-click="remove_item" phx-value-id={ti.id} data-confirm="Remove from trip?" class="btn btn-ghost btn-xs">×</button>
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

  def format_capacity(v) when is_float(v) do
    if v == Float.round(v), do: Integer.to_string(trunc(v)), else: :erlang.float_to_binary(v, decimals: 1)
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
              <.icon name="hero-bolt-mini" class="size-3" /><span class="hidden sm:inline">charged</span>
            </span>
            <span class="flex items-center justify-end gap-1 w-12 sm:w-24 shrink-0" aria-hidden="true">
              <.icon name="hero-archive-box-mini" class="size-3" /><span class="hidden sm:inline">packed</span>
            </span>
          </div>
          <ul class="divide-y divide-base-300">
            <li :for={ti <- Map.get(@grouped, cat, [])} class="flex items-center py-2 px-1 gap-2">
              <span class="flex-1 min-w-0 truncate text-sm">
                <span :if={ti.item.brand} class="opacity-60 mr-1 inline-block max-w-[7rem] sm:max-w-none truncate align-bottom">{ti.item.brand}</span>{ti.item.title}
              </span>
              <span class="text-xs opacity-60 shrink-0 tabular-nums whitespace-nowrap">
                <%= if ti.qty > 1 do %>
                  {ti.item.weight_g || 0} g × {ti.qty}
                <% else %>
                  ×1
                <% end %>
              </span>
              <span :if={ti.source == :kit} class="badge badge-xs shrink-0">kit</span>
              <%= if PackheavyWeb.TripLive.Show.needs_charging?(ti, @rechargeable_battery_ids) do %>
                <label class="flex items-center justify-end cursor-pointer w-12 sm:w-24 shrink-0" aria-label="charged">
                  <input type="checkbox" class="checkbox checkbox-sm print:hidden" checked={ti.charged} phx-click="toggle_charged" phx-value-id={ti.id} />
                  <span class="hidden print:inline text-base leading-none">{if ti.charged, do: "☑", else: "☐"}</span>
                </label>
              <% else %>
                <span class="w-12 sm:w-24 shrink-0 text-right opacity-20">—</span>
              <% end %>
              <label class="flex items-center justify-end cursor-pointer w-12 sm:w-24 shrink-0" aria-label="packed">
                <input type="checkbox" class="checkbox checkbox-sm print:hidden" checked={ti.packed} phx-click="toggle_packed" phx-value-id={ti.id} />
                <span class="hidden print:inline text-base leading-none">{if ti.packed, do: "☑", else: "☐"}</span>
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
        <button phx-click="complete" data-confirm="Complete trip and decrement food?" class="btn btn-success mt-2">Complete trip</button>
      <% true -> %>
        <p class="opacity-70 mt-2">Move the trip through Plan → Pack first.</p>
    <% end %>
    """
  end
end
