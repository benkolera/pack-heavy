defmodule PackheavyWeb.CableTypeLive.Index do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Inventory.CableType

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, build_form(socket.assigns.current_user))
     |> reload()}
  end

  defp reload(socket) do
    assign(socket, :cable_types, Inventory.list_cable_types!(actor: socket.assigns.current_user))
  end

  defp build_form(user) do
    AshPhoenix.Form.for_create(CableType, :create, actor: user)
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
         |> put_flash(:info, "Cable type added.")
         |> assign(:form, build_form(socket.assigns.current_user))
         |> reload()}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    ct = Inventory.get_cable_type!(id, actor: socket.assigns.current_user)
    Ash.destroy!(ct, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Deleted.") |> reload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-2xl font-bold">Cable types</h1>
      <p class="opacity-70 text-sm">e.g. USB-C, Micro-USB, Lightning. Used to match electronics to chargers.</p>

      <.form for={@form} phx-change="validate" phx-submit="save" class="flex gap-2 mt-2">
        <input type="text" name="form[name]" value={@form[:name].value} placeholder="Name" class="input input-bordered flex-1" />
        <button class="btn btn-primary">Add</button>
      </.form>

      <ul class="menu bg-base-200 rounded-box w-full mt-4">
        <li :for={ct <- @cable_types} class="flex flex-row justify-between items-center px-4 py-2">
          <span>{ct.name}</span>
          <button phx-click="delete" phx-value-id={ct.id} data-confirm="Delete cable type?" class="btn btn-ghost btn-xs">×</button>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
