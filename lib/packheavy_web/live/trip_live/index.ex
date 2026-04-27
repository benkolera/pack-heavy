defmodule PackheavyWeb.TripLive.Index do
  use PackheavyWeb, :live_view

  alias Packheavy.Trips
  alias Packheavy.Trips.Trip

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:form, nil) |> reload()}
  end

  defp reload(socket) do
    assign(socket, :trips, Trips.list_trips!(actor: socket.assigns.current_user))
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :new) do
    user = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_create(Trip, :create, actor: user)
      |> to_form()

    assign(socket, :form, form)
  end

  defp apply_action(socket, _), do: assign(socket, :form, nil)

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, trip} -> {:noreply, push_navigate(socket, to: ~p"/trips/#{trip.id}")}
      {:error, form} -> {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    trip = Trips.get_trip!(id, actor: socket.assigns.current_user)
    Ash.destroy!(trip, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Deleted.") |> reload()}
  end

  defp state_badge_class(:draft), do: "badge"
  defp state_badge_class(:packing), do: "badge badge-warning"
  defp state_badge_class(:complete), do: "badge badge-success"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">Trips</h1>
        <.link patch={~p"/trips/new"} class="btn btn-primary btn-sm">+ New trip</.link>
      </div>

      <%= if @form do %>
        <div class="card bg-base-200 p-4">
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-2">
            <input type="text" name="form[name]" value={@form[:name].value} placeholder="Trip name" class="input input-bordered w-full" />
            <div class="grid grid-cols-2 gap-2">
              <label class="form-control">
                <span class="label-text">Start date</span>
                <input type="date" name="form[start_date]" value={@form[:start_date].value} class="input input-bordered" />
              </label>
              <label class="form-control">
                <span class="label-text">End date</span>
                <input type="date" name="form[end_date]" value={@form[:end_date].value} class="input input-bordered" />
              </label>
            </div>
            <div class="flex gap-2 justify-end">
              <.link patch={~p"/trips"} class="btn btn-ghost">Cancel</.link>
              <button class="btn btn-primary">Create</button>
            </div>
          </.form>
        </div>
      <% end %>

      <table class="table">
        <thead>
          <tr><th>Name</th><th>Dates</th><th>State</th><th></th></tr>
        </thead>
        <tbody>
          <tr :for={trip <- @trips}>
            <td><.link navigate={~p"/trips/#{trip.id}"} class="link">{trip.name}</.link></td>
            <td class="text-sm opacity-70">
              {trip.start_date} <%= if trip.end_date, do: "→ #{trip.end_date}" %>
            </td>
            <td><span class={state_badge_class(trip.state)}>{trip.state}</span></td>
            <td class="text-right">
              <button phx-click="delete" phx-value-id={trip.id} data-confirm="Delete trip?" class="btn btn-ghost btn-xs">×</button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
