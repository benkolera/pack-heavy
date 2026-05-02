defmodule PackheavyWeb.TripDetailsLive do
  @moduledoc """
  Hike-details landing page for a trip — the equivalent of page 1 of
  the Google doc Ben currently writes by hand:

    * Trip overview (area, park/route URLs, departure/return,
      escalation criteria, gear highlights)
    * Hikers (group leader + members, with contact info per hiker)
    * Contacts (emergency primary + daily-checkin recipients)

  The pack planner lives at `/trips/:id/pack` (PackheavyWeb.TripLive.Show).
  Both pages share the trip-details summary header and the share panel
  via `PackheavyWeb.TripLive.Show.{trip_details_panel, share_panel}`.
  """

  use PackheavyWeb, :live_view

  alias Packheavy.Trips
  alias Packheavy.Trips.{Trip, TripContact, TripHiker}
  alias PackheavyWeb.TripLive.Show, as: TripShow

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    trip = load_trip!(id, user)

    {:ok,
     socket
     |> assign(:page_title, "Packheavy: #{trip.name}")
     |> assign(:trip_id, id)
     |> assign(:trip, trip)
     |> assign(:editing_details?, false)
     |> assign(:editing_overview?, false)
     |> assign(:editing_hiker_id, nil)
     |> assign(:editing_contact_id, nil)
     |> assign(:hiker_form, nil)
     |> assign(:contact_form, nil)
     |> assign(:overview_form, nil)}
  end

  defp load_trip!(id, user) do
    Ash.get!(Trip, id,
      actor: user,
      load: [
        :validation_report,
        :trip_legs,
        trip_items: [:item],
        trip_kits: [:kit],
        trip_hikers: [],
        trip_contacts: []
      ]
    )
  end

  defp reload(socket) do
    user = socket.assigns.current_user
    assign(socket, :trip, load_trip!(socket.assigns.trip_id, user))
  end

  # --- Trip-details panel (top-of-page summary) -----------------------

  @impl true
  def handle_event("save_details", %{"details" => params}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      name: params["name"],
      start_date: blank_to_nil(params["start_date"]),
      end_date: blank_to_nil(params["end_date"])
    }

    Trips.update_trip!(socket.assigns.trip, attrs, actor: user)

    {:noreply,
     socket
     |> put_flash(:info, "Trip details saved.")
     |> assign(:editing_details?, false)
     |> reload()}
  end

  def handle_event("edit_details", _, socket),
    do: {:noreply, assign(socket, :editing_details?, true)}

  def handle_event("cancel_edit_details", _, socket),
    do: {:noreply, assign(socket, :editing_details?, false)}

  # --- Share panel handlers (mirror of TripLive.Show) ------------------

  def handle_event("enable_sharing", _, socket) do
    Trips.enable_trip_sharing!(socket.assigns.trip, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Public link enabled.") |> reload()}
  end

  def handle_event("disable_sharing", _, socket) do
    Trips.disable_trip_sharing!(socket.assigns.trip, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Public link revoked.") |> reload()}
  end

  # --- Trip overview card --------------------------------------------

  def handle_event("edit_overview", _, socket) do
    form =
      AshPhoenix.Form.for_update(socket.assigns.trip, :update,
        actor: socket.assigns.current_user
      )
      |> to_form()

    {:noreply, socket |> assign(:editing_overview?, true) |> assign(:overview_form, form)}
  end

  def handle_event("cancel_edit_overview", _, socket) do
    {:noreply, socket |> assign(:editing_overview?, false) |> assign(:overview_form, nil)}
  end

  def handle_event("validate_overview", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :overview_form, AshPhoenix.Form.validate(socket.assigns.overview_form, params))}
  end

  def handle_event("save_overview", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.overview_form, params: params) do
      {:ok, _trip} ->
        {:noreply,
         socket
         |> put_flash(:info, "Trip overview saved.")
         |> assign(:editing_overview?, false)
         |> assign(:overview_form, nil)
         |> reload()}

      {:error, form} ->
        {:noreply, assign(socket, :overview_form, form)}
    end
  end

  # --- Hikers --------------------------------------------------------

  def handle_event("new_hiker", _, socket) do
    next_pos = length(socket.assigns.trip.trip_hikers)

    form =
      AshPhoenix.Form.for_create(TripHiker, :create, actor: socket.assigns.current_user)
      |> AshPhoenix.Form.validate(%{
        "trip_id" => socket.assigns.trip_id,
        "role" => "member",
        "position" => Integer.to_string(next_pos)
      })
      |> to_form()

    {:noreply, socket |> assign(:editing_hiker_id, :new) |> assign(:hiker_form, form)}
  end

  def handle_event("edit_hiker", %{"id" => id}, socket) do
    hiker = Enum.find(socket.assigns.trip.trip_hikers, &(&1.id == id))

    form =
      AshPhoenix.Form.for_update(hiker, :update, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, socket |> assign(:editing_hiker_id, id) |> assign(:hiker_form, form)}
  end

  def handle_event("cancel_edit_hiker", _, socket) do
    {:noreply, socket |> assign(:editing_hiker_id, nil) |> assign(:hiker_form, nil)}
  end

  def handle_event("validate_hiker", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :hiker_form, AshPhoenix.Form.validate(socket.assigns.hiker_form, params))}
  end

  def handle_event("save_hiker", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.hiker_form, params: params) do
      {:ok, _hiker} ->
        {:noreply,
         socket
         |> put_flash(:info, "Hiker saved.")
         |> assign(:editing_hiker_id, nil)
         |> assign(:hiker_form, nil)
         |> reload()}

      {:error, form} ->
        {:noreply, assign(socket, :hiker_form, form)}
    end
  end

  def handle_event("delete_hiker", %{"id" => id}, socket) do
    hiker = Enum.find(socket.assigns.trip.trip_hikers, &(&1.id == id))
    Trips.destroy_trip_hiker!(hiker, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Hiker removed.") |> reload()}
  end

  # --- Contacts ------------------------------------------------------

  def handle_event("new_contact", %{"kind" => kind}, socket) do
    next_pos = length(socket.assigns.trip.trip_contacts)

    form =
      AshPhoenix.Form.for_create(TripContact, :create, actor: socket.assigns.current_user)
      |> AshPhoenix.Form.validate(%{
        "trip_id" => socket.assigns.trip_id,
        "kind" => kind,
        "position" => Integer.to_string(next_pos)
      })
      |> to_form()

    {:noreply, socket |> assign(:editing_contact_id, {:new, kind}) |> assign(:contact_form, form)}
  end

  def handle_event("edit_contact", %{"id" => id}, socket) do
    contact = Enum.find(socket.assigns.trip.trip_contacts, &(&1.id == id))

    form =
      AshPhoenix.Form.for_update(contact, :update, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, socket |> assign(:editing_contact_id, id) |> assign(:contact_form, form)}
  end

  def handle_event("cancel_edit_contact", _, socket) do
    {:noreply, socket |> assign(:editing_contact_id, nil) |> assign(:contact_form, nil)}
  end

  def handle_event("validate_contact", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :contact_form, AshPhoenix.Form.validate(socket.assigns.contact_form, params))}
  end

  def handle_event("save_contact", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.contact_form, params: params) do
      {:ok, _c} ->
        {:noreply,
         socket
         |> put_flash(:info, "Contact saved.")
         |> assign(:editing_contact_id, nil)
         |> assign(:contact_form, nil)
         |> reload()}

      {:error, form} ->
        {:noreply, assign(socket, :contact_form, form)}
    end
  end

  def handle_event("delete_contact", %{"id" => id}, socket) do
    contact = Enum.find(socket.assigns.trip.trip_contacts, &(&1.id == id))
    Trips.destroy_trip_contact!(contact, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Contact removed.") |> reload()}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v), do: v

  # --- Render ------------------------------------------------------

  @impl true
  def render(assigns) do
    emergency = Enum.filter(assigns.trip.trip_contacts, &(&1.kind == :emergency_primary))
    daily = Enum.filter(assigns.trip.trip_contacts, &(&1.kind == :daily_checkin))

    assigns =
      assigns
      |> assign(:emergency_contacts, emergency)
      |> assign(:daily_contacts, daily)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.link navigate={~p"/trips"} class="link text-sm">← Trips</.link>
      <div class="flex flex-wrap justify-between items-center gap-2">
        <h1 class="text-2xl font-bold">
          {@trip.name}
          <span class="badge ml-2">{@trip.state}</span>
        </h1>
        <TripShow.share_panel trip={@trip} socket={@socket} />
      </div>

      <TripShow.trip_details_panel trip={@trip} editing?={@editing_details?} />

      <div role="tablist" class="tabs tabs-boxed">
        <span role="tab" class="tab tab-active">Details</span>
        <.link navigate={~p"/trips/#{@trip.id}/pack?tab=route"} role="tab" class="tab">Route</.link>
        <.link navigate={~p"/trips/#{@trip.id}/pack"} role="tab" class="tab">Plan</.link>
        <.link navigate={~p"/trips/#{@trip.id}/pack?tab=pack"} role="tab" class="tab">Pack</.link>
        <.link navigate={~p"/trips/#{@trip.id}/pack?tab=complete"} role="tab" class="tab">Complete</.link>
      </div>

      <.overview_card trip={@trip} editing?={@editing_overview?} form={@overview_form} />

      <.hikers_card
        trip={@trip}
        editing_hiker_id={@editing_hiker_id}
        hiker_form={@hiker_form}
      />

      <.contacts_card
        title="Emergency contact"
        kind={:emergency_primary}
        contacts={@emergency_contacts}
        editing_contact_id={@editing_contact_id}
        contact_form={@contact_form}
        empty_hint="Who calls emergency services if your group misses check-in?"
      />

      <.contacts_card
        title="Daily check-in contacts"
        kind={:daily_checkin}
        contacts={@daily_contacts}
        editing_contact_id={@editing_contact_id}
        contact_form={@contact_form}
        empty_hint="Friends or family who get daily updates while you're in the field."
      />
    </Layouts.app>
    """
  end

  # --- Components -----------------------------------------------------

  attr :trip, :any, required: true
  attr :editing?, :boolean, required: true
  attr :form, :any

  defp overview_card(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 space-y-2">
      <div class="flex justify-between items-center">
        <h2 class="font-semibold">Trip overview</h2>
        <button :if={!@editing?} phx-click="edit_overview" class="btn btn-ghost btn-xs">
          <.icon name="hero-pencil-square-mini" class="size-3.5" /> Edit
        </button>
      </div>

      <%= if @editing? && @form do %>
        <.form for={@form} phx-change="validate_overview" phx-submit="save_overview" class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Area</span>
            <input type="text" name={@form[:area].name} value={@form[:area].value} placeholder="Cradle Mountain → Lake St Claire" class="input input-bordered input-sm w-full" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Park URL</span>
            <input type="url" name={@form[:park_url].name} value={@form[:park_url].value} class="input input-bordered input-sm w-full" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Route URL</span>
            <input type="url" name={@form[:route_url].name} value={@form[:route_url].value} class="input input-bordered input-sm w-full" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Departure</span>
            <input type="datetime-local" name={@form[:departure_at].name} value={format_datetime_local(@form[:departure_at].value)} class="input input-bordered input-sm w-full" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-xs opacity-70">Return</span>
            <input type="datetime-local" name={@form[:return_at].name} value={format_datetime_local(@form[:return_at].value)} class="input input-bordered input-sm w-full" />
          </label>
          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Escalation criteria (when emergency contact should call services)</span>
            <textarea name={@form[:escalation_criteria].name} rows="3" class="textarea textarea-bordered textarea-sm w-full">{@form[:escalation_criteria].value}</textarea>
          </label>
          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Gear highlights (curated list for the handout)</span>
            <textarea name={@form[:gear_highlights].name} rows="4" class="textarea textarea-bordered textarea-sm w-full" placeholder="Garmin InReach&#10;First Aid Kit (snake bites)&#10;Topographic Map & Compass">{@form[:gear_highlights].value}</textarea>
          </label>
          <label class="flex flex-col gap-1 sm:col-span-2">
            <span class="text-xs opacity-70">Notes (Markdown — flights, accom, shuttles, links)</span>
            <textarea name={@form[:notes].name} rows="6" class="textarea textarea-bordered textarea-sm w-full font-mono text-xs" placeholder={"Flights:\n- QF 123 Sun 03 May, 8:30 → 11:50\nAccom:\n- [Cradle Mountain Lodge](https://example.com)\nShuttle:\n- 0428 555 123, departs 7:00am from carpark"}>{@form[:notes].value}</textarea>
          </label>
          <div class="sm:col-span-2 flex justify-end gap-2">
            <button type="button" phx-click="cancel_edit_overview" class="btn btn-ghost btn-sm">Cancel</button>
            <button class="btn btn-primary btn-sm">Save</button>
          </div>
        </.form>
      <% else %>
        <dl class="text-sm grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1">
          <div :if={@trip.area} class="sm:col-span-2"><dt class="opacity-60 inline">Area: </dt><dd class="inline">{@trip.area}</dd></div>
          <div :if={@trip.park_url}><dt class="opacity-60 inline">Park: </dt><dd class="inline"><.link href={@trip.park_url} class="link" target="_blank">{@trip.park_url}</.link></dd></div>
          <div :if={@trip.route_url}><dt class="opacity-60 inline">Route: </dt><dd class="inline"><.link href={@trip.route_url} class="link" target="_blank">{@trip.route_url}</.link></dd></div>
          <div :if={@trip.departure_at}><dt class="opacity-60 inline">Depart: </dt><dd class="inline">{format_datetime(@trip.departure_at)}</dd></div>
          <div :if={@trip.return_at}><dt class="opacity-60 inline">Return: </dt><dd class="inline">{format_datetime(@trip.return_at)}</dd></div>
          <div :if={@trip.escalation_criteria} class="sm:col-span-2"><dt class="opacity-60">Escalation criteria:</dt><dd class="whitespace-pre-line">{@trip.escalation_criteria}</dd></div>
          <div :if={@trip.gear_highlights} class="sm:col-span-2"><dt class="opacity-60">Gear highlights:</dt><dd class="whitespace-pre-line">{@trip.gear_highlights}</dd></div>
          <div :if={@trip.notes && @trip.notes != ""} class="sm:col-span-2">
            <dt class="opacity-60">Notes:</dt>
            <dd class="markdown text-sm">{PackheavyWeb.Markdown.render(@trip.notes)}</dd>
          </div>
          <div :if={empty_overview?(@trip)} class="opacity-60 italic sm:col-span-2">No overview yet — click Edit to fill in the high-level plan.</div>
        </dl>
      <% end %>
    </section>
    """
  end

  defp empty_overview?(trip) do
    is_nil(trip.area) and is_nil(trip.park_url) and is_nil(trip.route_url) and
      is_nil(trip.departure_at) and is_nil(trip.return_at) and
      is_nil(trip.escalation_criteria) and is_nil(trip.gear_highlights) and
      blank?(trip.notes)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp format_datetime(nil), do: ""

  defp format_datetime(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp format_datetime_local(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M")

  defp format_datetime_local(_), do: nil

  attr :trip, :any, required: true
  attr :editing_hiker_id, :any, required: true
  attr :hiker_form, :any

  defp hikers_card(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 space-y-3">
      <div class="flex justify-between items-center">
        <h2 class="font-semibold">Hiking group</h2>
        <button :if={@editing_hiker_id != :new} phx-click="new_hiker" class="btn btn-ghost btn-xs">
          + Add hiker
        </button>
      </div>

      <%= if @editing_hiker_id == :new && @hiker_form do %>
        <.hiker_form_card form={@hiker_form} title="New hiker" />
      <% end %>

      <%= if @trip.trip_hikers == [] && @editing_hiker_id != :new do %>
        <p class="opacity-60 italic text-sm">No hikers yet.</p>
      <% end %>

      <div :for={h <- Enum.sort_by(@trip.trip_hikers, & &1.position)} class="border-t border-base-300 pt-3 first:border-t-0 first:pt-0">
        <%= if @editing_hiker_id == h.id && @hiker_form do %>
          <.hiker_form_card form={@hiker_form} title={"Edit #{h.name}"} />
        <% else %>
          <div class="flex justify-between items-start gap-2">
            <div class="text-sm">
              <div class="font-semibold">
                {h.name}
                <span :if={h.role == :leader} class="badge badge-primary badge-xs ml-1">Leader</span>
              </div>
              <div :if={h.phone} class="opacity-70">📱 {h.phone}</div>
              <div :if={h.plb_hex_id || h.plb_serial} class="opacity-70 text-xs">
                <span :if={h.plb_hex_id}>📡 PLB <span class="font-mono">{h.plb_hex_id}</span></span>
                <span :if={h.plb_serial} class="ml-2">SN {h.plb_serial}</span>
              </div>
              <%= if h.role == :leader do %>
                <div :if={h.satellite_sms} class="opacity-70">🛰 {h.satellite_sms}</div>
                <div :if={h.location_tracker_url} class="opacity-70">
                  <.link href={h.location_tracker_url} class="link" target="_blank">Location tracker</.link>
                  <span :if={h.location_tracker_password}>· password "{h.location_tracker_password}"</span>
                </div>
                <div :if={h.weight_kg} class="opacity-70">⚖ {h.weight_kg}kg</div>
                <div :if={h.notes} class="opacity-70 whitespace-pre-line mt-1">{h.notes}</div>
              <% end %>
            </div>
            <div class="flex gap-1 shrink-0">
              <button phx-click="edit_hiker" phx-value-id={h.id} class="btn btn-ghost btn-xs">Edit</button>
              <button phx-click="delete_hiker" phx-value-id={h.id} data-confirm={"Remove #{h.name}?"} class="btn btn-ghost btn-xs text-error">×</button>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :title, :string, required: true

  defp hiker_form_card(assigns) do
    leader? = assigns.form[:role].value in [:leader, "leader"]
    assigns = assign(assigns, :leader?, leader?)

    ~H"""
    <.form for={@form} phx-change="validate_hiker" phx-submit="save_hiker" class="bg-base-100 rounded p-3 grid grid-cols-1 sm:grid-cols-2 gap-3">
      <h3 class="text-sm font-semibold sm:col-span-2">{@title}</h3>
      <input type="hidden" name={@form[:trip_id].name} value={@form[:trip_id].value} />
      <input type="hidden" name={@form[:position].name} value={@form[:position].value} />
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">Name</span>
        <input type="text" name={@form[:name].name} value={@form[:name].value} required class="input input-bordered input-sm w-full" />
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">Role</span>
        <select name={@form[:role].name} class="select select-bordered select-sm w-full">
          <option value="leader" selected={@form[:role].value in [:leader, "leader"]}>Leader</option>
          <option value="member" selected={@form[:role].value in [:member, "member", nil]}>Member</option>
        </select>
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">Phone</span>
        <input type="tel" name={@form[:phone].name} value={@form[:phone].value} class="input input-bordered input-sm w-full" />
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">PLB Hex ID / UIN</span>
        <input type="text" name={@form[:plb_hex_id].name} value={@form[:plb_hex_id].value} class="input input-bordered input-sm w-full font-mono" placeholder="15-char hex" />
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">PLB serial</span>
        <input type="text" name={@form[:plb_serial].name} value={@form[:plb_serial].value} class="input input-bordered input-sm w-full" />
      </label>
      <%= if @leader? do %>
        <label class="flex flex-col gap-1">
          <span class="text-xs opacity-70">Satellite SMS</span>
          <input type="tel" name={@form[:satellite_sms].name} value={@form[:satellite_sms].value} class="input input-bordered input-sm w-full" />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs opacity-70">Location tracker URL</span>
          <input type="url" name={@form[:location_tracker_url].name} value={@form[:location_tracker_url].value} class="input input-bordered input-sm w-full" />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs opacity-70">Tracker password</span>
          <input type="text" name={@form[:location_tracker_password].name} value={@form[:location_tracker_password].value} class="input input-bordered input-sm w-full" />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs opacity-70">Weight (kg)</span>
          <input type="number" step="0.1" min="0" name={@form[:weight_kg].name} value={@form[:weight_kg].value} class="input input-bordered input-sm w-full" />
        </label>
        <label class="flex flex-col gap-1 sm:col-span-2">
          <span class="text-xs opacity-70">Notes (illnesses, age, training)</span>
          <textarea name={@form[:notes].name} rows="3" class="textarea textarea-bordered textarea-sm w-full">{@form[:notes].value}</textarea>
        </label>
      <% else %>
        <p class="sm:col-span-2 text-xs opacity-60">
          Members only need a name and contact number — leader carries the satellite, tracker, weight, and group notes.
        </p>
      <% end %>
      <div class="sm:col-span-2 flex justify-end gap-2">
        <button type="button" phx-click="cancel_edit_hiker" class="btn btn-ghost btn-sm">Cancel</button>
        <button class="btn btn-primary btn-sm">Save</button>
      </div>
    </.form>
    """
  end

  attr :title, :string, required: true
  attr :kind, :atom, required: true
  attr :contacts, :list, required: true
  attr :editing_contact_id, :any, required: true
  attr :contact_form, :any
  attr :empty_hint, :string, required: true

  defp contacts_card(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 space-y-3">
      <div class="flex justify-between items-center">
        <h2 class="font-semibold">{@title}</h2>
        <button
          :if={@editing_contact_id != {:new, Atom.to_string(@kind)}}
          phx-click="new_contact"
          phx-value-kind={Atom.to_string(@kind)}
          class="btn btn-ghost btn-xs"
        >
          + Add
        </button>
      </div>

      <%= if @editing_contact_id == {:new, Atom.to_string(@kind)} && @contact_form do %>
        <.contact_form_card form={@contact_form} title="New contact" kind={@kind} />
      <% end %>

      <%= if @contacts == [] && @editing_contact_id != {:new, Atom.to_string(@kind)} do %>
        <p class="opacity-60 italic text-sm">{@empty_hint}</p>
      <% end %>

      <div :for={c <- Enum.sort_by(@contacts, & &1.position)} class="border-t border-base-300 pt-3 first:border-t-0 first:pt-0">
        <%= if @editing_contact_id == c.id && @contact_form do %>
          <.contact_form_card form={@contact_form} title={"Edit #{c.name}"} kind={@kind} />
        <% else %>
          <div class="flex justify-between items-start gap-2">
            <div class="text-sm">
              <div class="font-semibold">
                {c.name}
                <span :if={c.relationship} class="opacity-60 font-normal text-xs ml-1">({c.relationship})</span>
              </div>
              <div :if={c.phone} class="opacity-70">📱 {c.phone}</div>
              <div :if={c.escalation_criteria} class="opacity-70 whitespace-pre-line mt-1">{c.escalation_criteria}</div>
            </div>
            <div class="flex gap-1 shrink-0">
              <button phx-click="edit_contact" phx-value-id={c.id} class="btn btn-ghost btn-xs">Edit</button>
              <button phx-click="delete_contact" phx-value-id={c.id} data-confirm={"Remove #{c.name}?"} class="btn btn-ghost btn-xs text-error">×</button>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :title, :string, required: true
  attr :kind, :atom, required: true

  defp contact_form_card(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate_contact" phx-submit="save_contact" class="bg-base-100 rounded p-3 grid grid-cols-1 sm:grid-cols-2 gap-3">
      <h3 class="text-sm font-semibold sm:col-span-2">{@title}</h3>
      <input type="hidden" name={@form[:trip_id].name} value={@form[:trip_id].value} />
      <input type="hidden" name={@form[:kind].name} value={@form[:kind].value} />
      <input type="hidden" name={@form[:position].name} value={@form[:position].value} />
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">Name</span>
        <input type="text" name={@form[:name].name} value={@form[:name].value} required class="input input-bordered input-sm w-full" />
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-xs opacity-70">Relationship</span>
        <input type="text" name={@form[:relationship].name} value={@form[:relationship].value} placeholder="Close friend" class="input input-bordered input-sm w-full" />
      </label>
      <label class="flex flex-col gap-1 sm:col-span-2">
        <span class="text-xs opacity-70">Phone</span>
        <input type="tel" name={@form[:phone].name} value={@form[:phone].value} class="input input-bordered input-sm w-full" />
      </label>
      <label :if={@kind == :emergency_primary} class="flex flex-col gap-1 sm:col-span-2">
        <span class="text-xs opacity-70">Escalation criteria</span>
        <textarea name={@form[:escalation_criteria].name} rows="3" class="textarea textarea-bordered textarea-sm w-full" placeholder="If I don't check in by Mon 7pm…">{@form[:escalation_criteria].value}</textarea>
      </label>
      <div class="sm:col-span-2 flex justify-end gap-2">
        <button type="button" phx-click="cancel_edit_contact" class="btn btn-ghost btn-sm">Cancel</button>
        <button class="btn btn-primary btn-sm">Save</button>
      </div>
    </.form>
    """
  end
end
