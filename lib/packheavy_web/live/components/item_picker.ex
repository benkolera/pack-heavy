defmodule PackheavyWeb.ItemPicker do
  @moduledoc """
  Modal LiveComponent for picking items at multi-qty granularity. Each
  picked item holds a list of "slots" — `%{qty, carry_mode}` — so a
  single inventory item can be split across the trip in multiple ways
  (e.g. 2 water bottles in main pack + 1 in day pack).

  Required assigns:
    - id             : DOM id (string)
    - items          : list of `Packheavy.Inventory.Item` records
    - title          : modal title
    - confirm_label  : button label, e.g. "Save"
    - existing_slots : `%{item_id => [%{qty: n, carry_mode: m}, ...]}` —
                       per-item slot list to pre-populate. Items not in
                       the map are unchecked.
    - max_qty_for    : `%{item_id => integer}` or `:unlimited` — owned cap
                       per item (typically `item.qty`). Capped per-slot;
                       cross-slot total is enforced server-side via
                       `EnforceItemQtyAvailable`.
    - close_event    : phx-click event name on the parent for cancel/backdrop

  Optional:
    - with_carry_mode : boolean (default false). When true, slots show a
                        carry-mode select and a "+ Split" button. When
                        false, exactly one slot per item is allowed and
                        only qty is editable.

  On confirm, sends `{:item_picker_confirm, id, selected}` where
  `selected :: %{item_id => [%{qty, carry_mode}, ...]}`. Items omitted
  should be removed; an empty slot list also means remove.
  """
  use PackheavyWeb, :live_component

  @categories [
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

  @default_slot %{qty: 1, carry_mode: :main_pack}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       search: "",
       selected: %{},
       with_carry_mode: false,
       existing_slots: %{},
       initialized: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      if socket.assigns.initialized do
        socket
      else
        existing = assigns[:existing_slots] || %{}
        socket |> assign(:selected, existing) |> assign(:initialized, true)
      end

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :search, q)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    new =
      if Map.has_key?(selected, id) do
        Map.delete(selected, id)
      else
        Map.put(selected, id, [@default_slot])
      end

    {:noreply, assign(socket, :selected, new)}
  end

  def handle_event("add_slot", %{"id" => id}, socket) do
    slots = Map.get(socket.assigns.selected, id, [])
    {:noreply, assign(socket, :selected, Map.put(socket.assigns.selected, id, slots ++ [@default_slot]))}
  end

  def handle_event("remove_slot", %{"id" => id, "slot" => slot_idx}, socket) do
    slot_idx = parse_int(slot_idx, 0)
    slots = Map.get(socket.assigns.selected, id, [])
    new_slots = List.delete_at(slots, slot_idx)

    new_selected =
      if new_slots == [] do
        Map.delete(socket.assigns.selected, id)
      else
        Map.put(socket.assigns.selected, id, new_slots)
      end

    {:noreply, assign(socket, :selected, new_selected)}
  end

  def handle_event("set_slot_qty", %{"id" => id, "slot" => slot_idx, "value" => qty}, socket) do
    slot_idx = parse_int(slot_idx, 0)
    qty = parse_int(qty, 1) |> max(1)

    slots = Map.get(socket.assigns.selected, id, [])

    new_slots =
      List.update_at(slots, slot_idx, fn slot ->
        Map.put(slot || @default_slot, :qty, qty)
      end)

    {:noreply, assign(socket, :selected, Map.put(socket.assigns.selected, id, new_slots))}
  end

  def handle_event("set_slot_mode", %{"id" => id, "slot" => slot_idx, "mode" => mode}, socket) do
    slot_idx = parse_int(slot_idx, 0)

    mode_atom =
      case mode do
        "worn" -> :worn
        "day_pack" -> :day_pack
        "main_pack" -> :main_pack
        _ -> :main_pack
      end

    slots = Map.get(socket.assigns.selected, id, [])

    new_slots =
      List.update_at(slots, slot_idx, fn slot ->
        Map.put(slot || @default_slot, :carry_mode, mode_atom)
      end)

    {:noreply, assign(socket, :selected, Map.put(socket.assigns.selected, id, new_slots))}
  end

  def handle_event("clear", _, socket) do
    existing = socket.assigns[:existing_slots] || %{}
    {:noreply, assign(socket, search: "", selected: existing)}
  end

  def handle_event("confirm", _, socket) do
    send(self(), {:item_picker_confirm, socket.assigns.id, socket.assigns.selected})
    {:noreply, assign(socket, search: "", selected: %{}, initialized: false)}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(n, _) when is_integer(n), do: n
  defp parse_int(_, default), do: default

  defp matches?(_item, q) when q in [nil, ""], do: true

  defp matches?(item, q) do
    needle = String.downcase(q)
    haystacks = [item.brand || "", item.title || ""]
    Enum.any?(haystacks, fn h -> String.contains?(String.downcase(h), needle) end)
  end

  defp max_qty(_item, :unlimited), do: nil

  defp max_qty(item, max_qty_for) when is_map(max_qty_for) do
    Map.get(max_qty_for, item.id, item.qty || 0)
  end

  defp item_disabled?(item, existing_slots, max_qty_for) do
    not Map.has_key?(existing_slots, item.id) and
      case max_qty(item, max_qty_for) do
        nil -> false
        n -> n <= 0
      end
  end

  defp slot_total(slots), do: slots |> Enum.map(&Map.get(&1, :qty, 0)) |> Enum.sum()

  @impl true
  def render(assigns) do
    selected_count = map_size(assigns.selected)

    visible =
      assigns.items
      |> Enum.filter(&matches?(&1, assigns.search))
      |> Enum.sort_by(fn i -> String.downcase("#{i.brand || ""} #{i.title}") end)

    grouped =
      Enum.group_by(visible, fn i -> i.category_data.type end)

    categories =
      Enum.filter(@categories, fn {cat, _} -> Map.has_key?(grouped, cat) end)

    assigns =
      assigns
      |> assign(:selected_count, selected_count)
      |> assign(:grouped, grouped)
      |> assign(:visible_categories, categories)

    ~H"""
    <div>
      <dialog class="modal" open>
        <div class="modal-box max-w-3xl max-h-[85vh] flex flex-col">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold">{@title}</h2>
            <button type="button" phx-click="clear" phx-target={@myself} class="btn btn-ghost btn-xs">Clear</button>
          </div>

          <input
            type="text"
            phx-keyup="search"
            phx-target={@myself}
            phx-debounce="120"
            name="q"
            value={@search}
            placeholder="Search by brand or title…"
            class="input input-bordered w-full mb-3"
            autofocus
          />

          <div class="overflow-y-auto flex-1 space-y-4 pr-1">
            <%= if @visible_categories == [] do %>
              <p class="opacity-60 italic text-sm">No items match.</p>
            <% else %>
              <section :for={{cat, label} <- @visible_categories}>
                <h3 class="text-success text-xs font-bold uppercase tracking-wide border-b border-success pb-0.5 mb-1">{label}</h3>
                <ul class="divide-y divide-base-300">
                  <li :for={item <- Map.get(@grouped, cat, [])}
                      class={[
                        "py-2 px-1",
                        item_disabled?(item, @existing_slots, @max_qty_for) && "opacity-40"
                      ]}>
                    <div class="flex items-center gap-2">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-sm"
                        checked={Map.has_key?(@selected, item.id)}
                        disabled={item_disabled?(item, @existing_slots, @max_qty_for)}
                        phx-click="toggle"
                        phx-value-id={item.id}
                        phx-target={@myself}
                      />
                      <div class="flex-1 min-w-0 text-sm leading-tight">
                        <div class="truncate">
                          <span :if={item.brand} class="opacity-60 mr-1 inline-block max-w-[7rem] sm:max-w-none truncate align-bottom">{item.brand}</span>{item.title}
                          <span :if={Map.has_key?(@existing_slots, item.id)} class="badge badge-xs ml-1 align-middle">on trip</span>
                        </div>
                        <div class="text-xs opacity-50 tabular-nums">
                          {item.weight_g} g<%= if cap = max_qty(item, @max_qty_for) do %>
                            · max {cap}<%= if Map.has_key?(@selected, item.id) do %> · picked {slot_total(@selected[item.id])}<% end %>
                          <% end %>
                        </div>
                      </div>
                      <%= if Map.has_key?(@selected, item.id) and not @with_carry_mode do %>
                        <input
                          type="number"
                          min="1"
                          max={max_qty(item, @max_qty_for) || 999}
                          value={Map.get(@selected, item.id) |> List.first() |> Map.get(:qty, 1)}
                          phx-keyup="set_slot_qty"
                          phx-blur="set_slot_qty"
                          phx-value-id={item.id}
                          phx-value-slot="0"
                          phx-debounce="200"
                          phx-target={@myself}
                          name="qty"
                          class="input input-bordered input-xs w-14 shrink-0"
                        />
                      <% else %>
                        <span class="w-14 shrink-0"></span>
                      <% end %>
                    </div>

                    <%= if Map.has_key?(@selected, item.id) and @with_carry_mode do %>
                      <div class="ml-7 mt-2 space-y-1">
                        <div :for={{slot, idx} <- Enum.with_index(Map.get(@selected, item.id, []))} class="flex items-center gap-2 text-xs">
                          <span class="opacity-50 tabular-nums w-4 text-right">{idx + 1}.</span>
                          <input
                            type="number"
                            min="1"
                            max={max_qty(item, @max_qty_for) || 999}
                            value={slot.qty}
                            phx-keyup="set_slot_qty"
                            phx-blur="set_slot_qty"
                            phx-value-id={item.id}
                            phx-value-slot={idx}
                            phx-debounce="200"
                            phx-target={@myself}
                            name="qty"
                            class="input input-bordered input-xs w-14 tabular-nums"
                          />
                          <div class="join" role="radiogroup" aria-label="Carry mode">
                            <button
                              type="button"
                              phx-click="set_slot_mode"
                              phx-value-id={item.id}
                              phx-value-slot={idx}
                              phx-value-mode="main_pack"
                              phx-target={@myself}
                              class={["btn btn-xs join-item", slot.carry_mode == :main_pack && "btn-primary"]}
                            >Main</button>
                            <button
                              type="button"
                              phx-click="set_slot_mode"
                              phx-value-id={item.id}
                              phx-value-slot={idx}
                              phx-value-mode="day_pack"
                              phx-target={@myself}
                              class={["btn btn-xs join-item", slot.carry_mode == :day_pack && "btn-primary"]}
                            >Day</button>
                            <button
                              type="button"
                              phx-click="set_slot_mode"
                              phx-value-id={item.id}
                              phx-value-slot={idx}
                              phx-value-mode="worn"
                              phx-target={@myself}
                              class={["btn btn-xs join-item", slot.carry_mode == :worn && "btn-primary"]}
                            >Worn</button>
                          </div>
                          <button
                            type="button"
                            phx-click="remove_slot"
                            phx-value-id={item.id}
                            phx-value-slot={idx}
                            phx-target={@myself}
                            class="btn btn-ghost btn-xs"
                            title="Remove this split"
                          >
                            ×
                          </button>
                        </div>
                        <button
                          type="button"
                          phx-click="add_slot"
                          phx-value-id={item.id}
                          phx-target={@myself}
                          class="btn btn-ghost btn-xs"
                          title="Split this item across another carry mode"
                        >
                          + Split
                        </button>
                      </div>
                    <% end %>
                  </li>
                </ul>
              </section>
            <% end %>
          </div>

          <div class="modal-action mt-3">
            <button type="button" phx-click={@close_event} class="btn btn-ghost">Cancel</button>
            <button
              type="button"
              phx-click="confirm"
              phx-target={@myself}
              class="btn btn-primary"
            >
              {@confirm_label} ({@selected_count})
            </button>
          </div>
        </div>
        <button type="button" phx-click={@close_event} class="modal-backdrop" aria-label="close">close</button>
      </dialog>
    </div>
    """
  end
end
