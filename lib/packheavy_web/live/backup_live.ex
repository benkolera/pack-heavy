defmodule PackheavyWeb.BackupLive do
  use PackheavyWeb, :live_view

  alias Packheavy.{Backup, Inventory, Trips}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Packheavy: Backup")
     |> assign(:pending, nil)
     |> assign(:error, nil)
     |> allow_upload(:backup,
       accept: ~w(.json application/json),
       max_entries: 1,
       max_file_size: 10_000_000
     )
     |> assign_counts()}
  end

  defp assign_counts(socket) do
    user = socket.assigns.current_user

    assign(socket,
      counts: %{
        cable_types: length(Inventory.list_cable_types!(actor: user)),
        battery_types: length(Inventory.list_battery_types!(actor: user)),
        items: length(Inventory.list_items!(actor: user)),
        kits: length(Inventory.list_kits!(actor: user)),
        trips: length(Trips.list_trips!(actor: user))
      }
    )
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :backup, ref)}
  end

  def handle_event("preview-restore", _params, socket) do
    [parsed | _] =
      consume_uploaded_entries(socket, :backup, fn %{path: path}, _entry ->
        {:ok, parse_or_error(path)}
      end)

    case parsed do
      {:ok, data} ->
        {:noreply, assign(socket, pending: data, error: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, pending: nil, error: msg)}
    end
  end

  def handle_event("cancel-restore", _params, socket) do
    {:noreply, assign(socket, pending: nil, error: nil)}
  end

  def handle_event("confirm-restore", _params, %{assigns: %{pending: data}} = socket)
      when is_map(data) do
    user = socket.assigns.current_user

    try do
      summary = Backup.restore!(user, data)

      {:noreply,
       socket
       |> put_flash(
         :info,
         "Restored #{summary.cable_types} cable types, #{summary.battery_types} battery types, " <>
           "#{summary.items} items, #{summary.kits} kits."
       )
       |> assign(pending: nil, error: nil)
       |> assign_counts()}
    rescue
      e ->
        {:noreply,
         socket
         |> assign(error: "Restore failed: #{Exception.message(e)}", pending: nil)}
    end
  end

  defp parse_or_error(path) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body) do
      {:ok, data}
    else
      {:error, %Jason.DecodeError{} = err} ->
        {:error, "JSON parse error: #{Exception.message(err)}"}

      {:error, reason} ->
        {:error, "Could not read file: #{inspect(reason)}"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-6 max-w-2xl">
        <div>
          <h1 class="text-2xl font-bold">Backup &amp; Restore</h1>
          <p class="opacity-70 text-sm mt-1">
            Export your inventory + kits as a single JSON file, or restore from one.
            Trips are not exported (they're per-trip packing state, not gear), but they
            are wiped on restore.
          </p>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-2">Current data</h2>
          <ul class="text-sm space-y-1">
            <li>{@counts.cable_types} cable types</li>
            <li>{@counts.battery_types} battery types</li>
            <li>{@counts.items} items</li>
            <li>{@counts.kits} kits</li>
            <li>{@counts.trips} trips</li>
          </ul>
        </div>

        <div class="card bg-base-200 p-4 space-y-3">
          <h2 class="font-semibold">Export</h2>
          <p class="text-sm opacity-70">
            Downloads a JSON snapshot of your cable types, battery types, items, and
            kits. Save it somewhere safe.
          </p>
          <a href={~p"/backup/export"} class="btn btn-primary w-fit">Download backup</a>
        </div>

        <div class="card bg-base-200 p-4 space-y-3">
          <h2 class="font-semibold">Restore</h2>
          <div class="alert alert-warning text-sm">
            <span>
              <strong>Destructive.</strong>
              Restoring will <strong>delete every trip, kit, item, cable type, and battery type</strong>
              you currently have, then load the file's contents. There is no undo.
            </span>
          </div>

          <form phx-change="validate" phx-submit="preview-restore">
            <.live_file_input upload={@uploads.backup} class="file-input file-input-bordered w-full" />
            <div :for={entry <- @uploads.backup.entries} class="text-sm mt-2 flex items-center gap-2">
              <span>{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs"
              >
                Remove
              </button>
            </div>
            <div :for={err <- upload_errors(@uploads.backup)} class="text-error text-sm mt-1">
              {Phoenix.Naming.humanize(err)}
            </div>
            <button
              type="submit"
              class="btn btn-warning mt-3"
              disabled={@uploads.backup.entries == []}
            >
              Preview restore
            </button>
          </form>

          <div :if={@error} class="alert alert-error text-sm">{@error}</div>
        </div>
      </div>

      <dialog class="modal" open={!is_nil(@pending)}>
        <div :if={@pending} class="modal-box max-w-lg">
          <h3 class="font-bold text-lg">Confirm restore</h3>
          <p class="py-2 text-sm">
            About to wipe your data and replace it with the contents of this file:
          </p>

          <div class="bg-base-200 p-3 rounded text-sm space-y-1">
            <div>Backup version: {@pending["version"]}</div>
            <div :if={@pending["exported_at"]}>Exported: {@pending["exported_at"]}</div>
            <div>{length(@pending["cable_types"] || [])} cable types</div>
            <div>{length(@pending["battery_types"] || [])} battery types</div>
            <div>{length(@pending["items"] || [])} items</div>
            <div>{length(@pending["kits"] || [])} kits</div>
          </div>

          <p class="py-2 text-sm font-semibold text-warning">
            All current trips ({@counts.trips}), kits ({@counts.kits}), and items ({@counts.items}) will be deleted first.
          </p>

          <div class="modal-action">
            <button type="button" phx-click="cancel-restore" class="btn btn-ghost">Cancel</button>
            <button type="button" phx-click="confirm-restore" class="btn btn-error">
              Wipe and restore
            </button>
          </div>
        </div>
        <button
          type="button"
          phx-click="cancel-restore"
          class="modal-backdrop"
          aria-label="close"
        >
          close
        </button>
      </dialog>
    </Layouts.app>
    """
  end
end
