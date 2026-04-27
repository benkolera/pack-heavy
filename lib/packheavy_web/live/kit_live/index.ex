defmodule PackheavyWeb.KitLive.Index do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Inventory.Kit

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Packheavy: Kits", form: nil) |> reload()}
  end

  defp reload(socket) do
    user = socket.assigns.current_user
    kits =
      Kit
      |> Ash.Query.load([:item_count])
      |> Ash.read!(actor: user)

    assign(socket, :kits, kits)
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :new) do
    user = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_create(Kit, :create, actor: user)
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
      {:ok, kit} ->
        {:noreply, push_navigate(socket, to: ~p"/kits/#{kit.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    kit = Inventory.get_kit!(id, actor: socket.assigns.current_user)
    Ash.destroy!(kit, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Deleted.") |> reload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">Kits</h1>
        <.link patch={~p"/kits/new"} class="btn btn-primary btn-sm">+ New kit</.link>
      </div>

      <%= if @form do %>
        <div class="card bg-base-200 p-4">
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-2">
            <input type="text" name="form[name]" value={@form[:name].value} placeholder="Kit name" class="input input-bordered w-full" />
            <textarea name="form[description]" placeholder="Description" class="textarea textarea-bordered w-full">{@form[:description].value}</textarea>
            <div class="flex gap-2 justify-end">
              <.link patch={~p"/kits"} class="btn btn-ghost">Cancel</.link>
              <button class="btn btn-primary">Create</button>
            </div>
          </.form>
        </div>
      <% end %>

      <table class="table">
        <thead>
          <tr><th>Name</th><th class="text-right">Items</th><th></th></tr>
        </thead>
        <tbody>
          <tr :for={kit <- @kits}>
            <td><.link navigate={~p"/kits/#{kit.id}"} class="link">{kit.name}</.link></td>
            <td class="text-right">{kit.item_count}</td>
            <td class="text-right">
              <button phx-click="delete" phx-value-id={kit.id} data-confirm="Delete kit?" class="btn btn-ghost btn-xs">×</button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
