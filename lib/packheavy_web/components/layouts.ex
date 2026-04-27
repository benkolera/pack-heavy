defmodule PackheavyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PackheavyWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :any, default: nil, doc: "the currently signed-in user"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1">
        <.link navigate={~p"/dashboard"} class="flex items-center gap-2 text-lg font-semibold">
          <img src={~p"/images/logo.svg"} alt="" class="size-7" />
          <span>packheavy</span>
        </.link>
      </div>

      <%!-- Desktop / wide screens: inline links --%>
      <div class="flex-none hidden md:block">
        <ul class="flex px-1 space-x-2 items-center">
          <li><.link navigate={~p"/items"} class="btn btn-ghost btn-sm">Items</.link></li>
          <li><.link navigate={~p"/kits"} class="btn btn-ghost btn-sm">Kits</.link></li>
          <li><.link navigate={~p"/trips"} class="btn btn-ghost btn-sm">Trips</.link></li>
          <li><.link navigate={~p"/cable-types"} class="btn btn-ghost btn-sm">Cables</.link></li>
          <li><.link navigate={~p"/battery-types"} class="btn btn-ghost btn-sm">Batteries</.link></li>
          <li><.theme_toggle /></li>
          <%= if @current_user do %>
            <li>
              <.link href={~p"/sign-out"} method="delete" class="btn btn-ghost btn-sm">Sign out</.link>
            </li>
          <% end %>
        </ul>
      </div>

      <%!-- Mobile / narrow screens: primary links + hamburger for the rest --%>
      <div class="flex-none md:hidden flex items-center gap-1">
        <.link navigate={~p"/items"} class="btn btn-ghost btn-sm">Items</.link>
        <.link navigate={~p"/trips"} class="btn btn-ghost btn-sm">Trips</.link>
        <details class="dropdown dropdown-end">
          <summary class="btn btn-ghost btn-sm" aria-label="Open menu">
            <.icon name="hero-bars-3" class="size-5" />
          </summary>
          <ul tabindex="0" class="dropdown-content menu bg-base-200 rounded-box z-[1] w-56 p-2 shadow mt-2 gap-1">
            <li><.link navigate={~p"/kits"}>Kits</.link></li>
            <li><.link navigate={~p"/cable-types"}>Cables</.link></li>
            <li><.link navigate={~p"/battery-types"}>Batteries</.link></li>
            <li class="border-t border-base-300 mt-1 pt-2">
              <div class="flex justify-center hover:bg-transparent focus:bg-transparent p-1">
                <.theme_toggle />
              </div>
            </li>
            <%= if @current_user do %>
              <li class="border-t border-base-300 mt-1 pt-1">
                <.link href={~p"/sign-out"} method="delete">Sign out</.link>
              </li>
            <% end %>
          </ul>
        </details>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-5xl xl:max-w-7xl space-y-4">
        <div class="hidden print:flex items-center gap-2 pb-2 mb-2 border-b border-base-300">
          <img src={~p"/images/logo.svg"} alt="" class="size-8" />
          <span class="text-xl font-semibold">packheavy</span>
        </div>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
