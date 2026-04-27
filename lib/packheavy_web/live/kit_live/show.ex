defmodule PackheavyWeb.KitLive.Show do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    items = Inventory.list_items!(actor: user)

    {:ok,
     socket
     |> assign(:kit_id, id)
     |> assign(:items, items)
     |> assign(:picker_open, false)
     |> reload()}
  end

  defp reload(socket) do
    kit =
      Ash.get!(Packheavy.Inventory.Kit, socket.assigns.kit_id,
        actor: socket.assigns.current_user,
        load: [kit_items: [:item]]
      )

    socket
    |> assign(:kit, kit)
    |> assign(:page_title, "Packheavy: Kit · #{kit.name}")
  end

  defp existing_qty_on_kit(kit) do
    kit.kit_items |> Map.new(fn ki -> {ki.item_id, ki.qty} end)
  end

  @impl true
  def handle_event("open_picker", _, socket) do
    {:noreply, assign(socket, :picker_open, true)}
  end

  def handle_event("close_picker", _, socket) do
    {:noreply, assign(socket, :picker_open, false)}
  end

  def handle_event("remove_item", %{"id" => id}, socket) do
    Packheavy.Inventory.KitItem
    |> Ash.get!(id, actor: socket.assigns.current_user)
    |> Ash.destroy!(actor: socket.assigns.current_user)

    {:noreply, reload(socket)}
  end

  @impl true
  def handle_info({:item_picker_confirm, "kit-item-picker", selected}, socket) do
    user = socket.assigns.current_user
    kit_id = socket.assigns.kit_id

    existing_by_item =
      socket.assigns.kit.kit_items |> Map.new(fn ki -> {ki.item_id, ki} end)

    item_ids = MapSet.union(MapSet.new(Map.keys(selected)), MapSet.new(Map.keys(existing_by_item)))

    Enum.each(item_ids, fn item_id ->
      desired = Map.get(selected, item_id, 0)
      existing = Map.get(existing_by_item, item_id)

      cond do
        existing && desired == existing.qty ->
          :ok

        desired == 0 && existing ->
          Ash.destroy!(existing, actor: user)

        existing ->
          Ash.update!(existing, %{qty: desired}, actor: user)

        true ->
          Inventory.add_kit_item!(
            %{kit_id: kit_id, item_id: item_id, qty: desired},
            actor: user
          )
      end
    end)

    {:noreply,
     socket
     |> assign(:picker_open, false)
     |> put_flash(:info, "Kit updated.")
     |> reload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.link navigate={~p"/kits"} class="link text-sm">← Kits</.link>
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-bold">{@kit.name}</h1>
          <p class="opacity-70 text-sm">{@kit.description}</p>
        </div>
        <button phx-click="open_picker" class="btn btn-primary btn-sm">+ Add items</button>
      </div>

      <h2 class="text-lg font-semibold mt-4">Items in this kit</h2>
      <%= if @kit.kit_items == [] do %>
        <p class="opacity-70 italic">Empty — click "Add items" above.</p>
      <% else %>
        <table class="table">
          <thead>
            <tr><th>Item</th><th class="text-right">Qty</th><th></th></tr>
          </thead>
          <tbody>
            <tr :for={ki <- @kit.kit_items}>
              <td>
                <span :if={ki.item.brand} class="opacity-60 mr-1">{ki.item.brand}</span>{ki.item.title}
              </td>
              <td class="text-right">{ki.qty}</td>
              <td class="text-right">
                <button phx-click="remove_item" phx-value-id={ki.id} class="btn btn-ghost btn-xs">×</button>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>

      <%= if @picker_open do %>
        <.live_component
          module={PackheavyWeb.ItemPicker}
          id="kit-item-picker"
          items={@items}
          existing_qty={existing_qty_on_kit(@kit)}
          max_qty_for={:unlimited}
          title={"Items in " <> @kit.name}
          confirm_label="Save"
          close_event="close_picker"
        />
      <% end %>
    </Layouts.app>
    """
  end
end
