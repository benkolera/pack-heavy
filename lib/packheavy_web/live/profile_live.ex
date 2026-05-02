defmodule PackheavyWeb.ProfileLive do
  @moduledoc """
  Edit the current user's profile. Fields here are the defaults that
  get copied into a leader `TripHiker` at trip-create time. Editing
  them later doesn't retroactively rewrite past trips.
  """

  use PackheavyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_update(user, :update_profile, actor: user)
      |> to_form()

    {:ok,
     socket
     |> assign(:page_title, "Packheavy: Profile")
     |> assign(:form, form)}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, user} ->
        # Re-build the form against the freshly-saved user so subsequent
        # validates run against the new values.
        form =
          AshPhoenix.Form.for_update(user, :update_profile, actor: user)
          |> to_form()

        {:noreply,
         socket
         |> put_flash(:info, "Profile saved.")
         |> assign(:current_user, user)
         |> assign(:form, form)}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-2xl space-y-4">
        <div>
          <h1 class="text-2xl font-bold">Profile</h1>
          <p class="text-sm opacity-70">
            These details are copied into the leader hiker on every new trip you create.
            Changing them here does not rewrite past trips.
          </p>
        </div>

        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          class="card bg-base-200 p-4 grid grid-cols-1 sm:grid-cols-2 gap-3"
        >
          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Email</span>
            <input
              type="email"
              value={to_string(@current_user.email)}
              disabled
              class="input input-bordered input-sm w-full opacity-60"
            />
          </label>

          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Display name</span>
            <input
              type="text"
              name={@form[:name].name}
              value={@form[:name].value}
              placeholder="Ben Kolera"
              class="input input-bordered input-sm w-full"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Phone</span>
            <input
              type="tel"
              name={@form[:phone].name}
              value={@form[:phone].value}
              placeholder="0488 145 427"
              class="input input-bordered input-sm w-full"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Satellite SMS number</span>
            <input
              type="tel"
              name={@form[:satellite_sms].name}
              value={@form[:satellite_sms].value}
              placeholder="+61 405 894 195"
              class="input input-bordered input-sm w-full"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Location tracker URL</span>
            <input
              type="url"
              name={@form[:location_tracker_url].name}
              value={@form[:location_tracker_url].value}
              placeholder="https://share.garmin.com/…"
              class="input input-bordered input-sm w-full"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Location tracker password</span>
            <input
              type="text"
              name={@form[:location_tracker_password].name}
              value={@form[:location_tracker_password].value}
              class="input input-bordered input-sm w-full"
            />
          </label>

          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Default hiker weight (kg)</span>
            <input
              type="number"
              step="0.1"
              min="0"
              name={@form[:default_hiker_weight_kg].name}
              value={@form[:default_hiker_weight_kg].value}
              class="input input-bordered input-sm w-full"
            />
          </label>

          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">
              Default hiker notes (illnesses/conditions/experience/age/training)
            </span>
            <textarea
              name={@form[:default_hiker_notes].name}
              rows="4"
              class="textarea textarea-bordered textarea-sm w-full"
              placeholder="No illnesses or conditions&#10;Experienced remote hiker&#10;39 years old&#10;First aid trained"
            >{@form[:default_hiker_notes].value}</textarea>
          </label>

          <div class="sm:col-span-2 flex justify-end">
            <button class="btn btn-primary btn-sm">Save profile</button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
