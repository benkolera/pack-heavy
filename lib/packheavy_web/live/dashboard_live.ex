defmodule PackheavyWeb.DashboardLive do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Trips

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_dashboard(socket)}
  end

  defp assign_dashboard(socket) do
    user = socket.assigns.current_user

    items = Inventory.list_items!(actor: user)
    kits = Inventory.list_kits!(actor: user)
    trips = Trips.list_trips!(actor: user)

    upcoming = Enum.filter(trips, fn t -> t.state in [:draft, :packing] end)

    total_weight =
      items
      |> Enum.map(& &1.weight_g)
      |> Enum.sum()

    socket
    |> assign(items: items, kits: kits, trips: trips, upcoming: upcoming, total_weight: total_weight)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-2xl font-bold">Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Items in inventory</div>
          <div class="text-3xl font-bold">{length(@items)}</div>
          <div class="text-xs opacity-60">Total weight: {@total_weight} g</div>
        </div>
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Kits</div>
          <div class="text-3xl font-bold">{length(@kits)}</div>
        </div>
        <div class="card bg-base-200 p-4">
          <div class="text-sm opacity-70">Upcoming trips</div>
          <div class="text-3xl font-bold">{length(@upcoming)}</div>
        </div>
      </div>

      <div>
        <h2 class="text-lg font-semibold mt-4">Upcoming trips</h2>
        <%= if @upcoming == [] do %>
          <p class="opacity-70">No upcoming trips. <.link navigate={~p"/trips"} class="link">Create one</.link>.</p>
        <% else %>
          <ul class="menu bg-base-200 rounded-box w-full">
            <li :for={trip <- @upcoming}>
              <.link navigate={~p"/trips/#{trip.id}"}>
                {trip.name} <span class="badge badge-sm">{trip.state}</span>
              </.link>
            </li>
          </ul>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
