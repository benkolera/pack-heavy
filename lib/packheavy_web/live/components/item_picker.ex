defmodule PackheavyWeb.ItemPicker do
  @moduledoc """
  A modal LiveComponent for picking multiple inventory items at once,
  grouped by category, with search. Used by Kit and Trip pages.

  Required assigns:
    - id            : DOM id (string)
    - items         : list of `Packheavy.Inventory.Item` records
    - title         : modal title
    - confirm_label : button label, e.g. "Save"
    - existing_qty  : %{item_id => current_qty_total} — items already on
                      kit/trip, pre-checked with their current qty
    - max_qty_for   : %{item_id => integer} or `:unlimited` — upper cap per
                      item. Typically set to `item.qty` (total owned) on trips.
    - close_event   : phx-click event name on the parent for cancel/backdrop

  On confirm, sends `{:item_picker_confirm, id, %{item_id => qty}}` to the
  parent. The map represents the desired state — items omitted should be
  removed; qty 0 also means remove. The parent computes the diff vs current.
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

  @impl true
  def mount(socket) do
    {:ok, assign(socket, search: "", selected: %{}, initialized: false)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      if socket.assigns.initialized do
        socket
      else
        existing = assigns[:existing_qty] || %{}
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
        Map.put(selected, id, 1)
      end

    {:noreply, assign(socket, :selected, new)}
  end

  def handle_event("set_qty", %{"id" => id, "value" => qty}, socket) do
    qty =
      case Integer.parse(qty || "") do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    {:noreply, assign(socket, :selected, Map.put(socket.assigns.selected, id, qty))}
  end

  def handle_event("clear", _, socket) do
    existing = socket.assigns[:existing_qty] || %{}
    {:noreply, assign(socket, search: "", selected: existing)}
  end

  def handle_event("confirm", _, socket) do
    send(self(), {:item_picker_confirm, socket.assigns.id, socket.assigns.selected})
    {:noreply, assign(socket, search: "", selected: %{}, initialized: false)}
  end

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

  # Owned-out only when the cap is 0 AND the item isn't already on the trip.
  # An item already on the trip with cap>=its qty is editable (decrementable).
  defp item_disabled?(item, existing_qty, max_qty_for) do
    not Map.has_key?(existing_qty, item.id) and
      case max_qty(item, max_qty_for) do
        nil -> false
        n -> n <= 0
      end
  end

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
                        "flex items-center gap-2 py-2 px-1",
                        item_disabled?(item, @existing_qty, @max_qty_for) && "opacity-40"
                      ]}>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      checked={Map.has_key?(@selected, item.id)}
                      disabled={item_disabled?(item, @existing_qty, @max_qty_for)}
                      phx-click="toggle"
                      phx-value-id={item.id}
                      phx-target={@myself}
                    />
                    <div class="flex-1 min-w-0 truncate text-sm">
                      <span :if={item.brand} class="opacity-60 mr-1">{item.brand}</span>{item.title}
                      <span :if={Map.has_key?(@existing_qty, item.id)} class="badge badge-xs ml-2">on trip</span>
                    </div>
                    <span class="opacity-50 text-xs tabular-nums w-16 text-right">
                      <%= if cap = max_qty(item, @max_qty_for) do %>
                        max {cap}
                      <% end %>
                    </span>
                    <span class="opacity-60 text-xs tabular-nums w-14 text-right">{item.weight_g} g</span>
                    <%= if Map.has_key?(@selected, item.id) do %>
                      <input
                        type="number"
                        min="1"
                        max={max_qty(item, @max_qty_for) || 999}
                        value={Map.get(@selected, item.id)}
                        phx-keyup="set_qty"
                        phx-blur="set_qty"
                        phx-value-id={item.id}
                        phx-debounce="200"
                        phx-target={@myself}
                        name="qty"
                        class="input input-bordered input-xs w-16"
                      />
                    <% else %>
                      <span class="w-16"></span>
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
