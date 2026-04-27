defmodule PackheavyWeb.BatteryTypeLive.Index do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Inventory.BatteryType

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, build_form(socket.assigns.current_user))
     |> reload()}
  end

  defp reload(socket) do
    assign(socket, :battery_types, Inventory.list_battery_types!(actor: socket.assigns.current_user))
  end

  defp build_form(user) do
    AshPhoenix.Form.for_create(BatteryType, :create, actor: user)
    |> to_form()
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Battery type added.")
         |> assign(:form, build_form(socket.assigns.current_user))
         |> reload()}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    bt = Inventory.get_battery_type!(id, actor: socket.assigns.current_user)
    Ash.destroy!(bt, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Deleted.") |> reload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-2xl font-bold">Battery types</h1>
      <p class="opacity-70 text-sm">e.g. AA, AAA, CR2032. Used for consumable-battery electronics.</p>

      <.form for={@form} phx-change="validate" phx-submit="save" class="flex gap-2 mt-2 items-center">
        <input type="text" name="form[name]" value={@form[:name].value} placeholder="Name" class="input input-bordered flex-1" />
        <label class="flex items-center gap-2 cursor-pointer select-none px-2">
          <input type="hidden" name="form[rechargeable]" value="false" />
          <input type="checkbox" name="form[rechargeable]" value="true" checked={@form[:rechargeable].value in [true, "true"]} class="checkbox checkbox-sm" />
          <span class="text-sm">Rechargeable</span>
        </label>
        <button class="btn btn-primary">Add</button>
      </.form>

      <ul class="menu bg-base-200 rounded-box w-full mt-4">
        <li :for={bt <- @battery_types} class="flex flex-row justify-between items-center px-4 py-2">
          <span>
            {bt.name}
            <span :if={bt.rechargeable} class="badge badge-sm badge-success ml-2">rechargeable</span>
          </span>
          <button phx-click="delete" phx-value-id={bt.id} data-confirm="Delete battery type?" class="btn btn-ghost btn-xs">×</button>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
