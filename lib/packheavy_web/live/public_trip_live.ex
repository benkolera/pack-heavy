defmodule PackheavyWeb.PublicTripLive do
  @moduledoc """
  Read-only public view of a trip's gear list. Reached via
  `/share/trip/:token` where `:token` is the opaque share token set on
  the trip via `Trips.enable_trip_sharing!/1`.

  Authorization: handled by the `:read_by_share_token` action's policy
  bypass on `Packheavy.Trips.Trip`. The action filter requires a
  non-nil share_token AND a match — there is no way to enumerate trips
  through this route. We never pass `actor:` here; the policy lets the
  action through without one.

  Reuses public helpers from PackheavyWeb.TripLive.Show
  (`weight_breakdown`, `food_calories`, `pack_capacity`,
  `format_capacity`, `trip_days`) so totals are computed identically
  to the planning view.
  """

  use PackheavyWeb, :live_view

  alias Packheavy.Trips
  alias PackheavyWeb.TripLive.Show, as: TripShow

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Trips.read_trip_by_share_token(token,
           load: [:validation_report, trip_items: [:item]]
         ) do
      {:ok, %{} = trip} ->
        {:ok,
         socket
         |> assign(:page_title, "#{trip.name} · packheavy")
         |> assign(:trip, trip)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Not found · packheavy")
         |> assign(:trip, nil)}
    end
  end

  @impl true
  def render(%{trip: nil} = assigns) do
    ~H"""
    <main class="min-h-screen p-8 flex items-center justify-center">
      <div class="max-w-md text-center space-y-2">
        <h1 class="text-2xl font-bold">Not found</h1>
        <p class="opacity-70 text-sm">
          This share link is invalid or has been revoked.
        </p>
      </div>
    </main>
    """
  end

  def render(assigns) do
    grouped =
      assigns.trip.trip_items
      |> Enum.sort_by(fn ti ->
        item = ti.item
        String.downcase("#{item && item.brand || ""} #{item && item.title}")
      end)
      |> Enum.group_by(fn ti ->
        case ti.item && ti.item.category_data do
          %Ash.Union{type: t} -> t
          _ -> :other
        end
      end)

    visible_categories =
      Enum.filter(category_order(), fn {cat, _} -> Map.has_key?(grouped, cat) end)

    section_weight = fn cat ->
      grouped
      |> Map.get(cat, [])
      |> Enum.map(fn ti -> (ti.item.weight_g || 0) * ti.qty end)
      |> Enum.sum()
    end

    section_capacity = fn cat ->
      total =
        grouped
        |> Map.get(cat, [])
        |> Enum.map(fn ti ->
          case TripShow.pack_capacity(ti) do
            v when is_number(v) -> v * ti.qty
            _ -> 0
          end
        end)
        |> Enum.sum()

      if total > 0, do: total, else: nil
    end

    section_calories = fn cat ->
      total =
        grouped
        |> Map.get(cat, [])
        |> Enum.map(fn ti ->
          case TripShow.food_calories(ti) do
            c when is_integer(c) -> c * ti.qty
            _ -> 0
          end
        end)
        |> Enum.sum()

      if total > 0, do: total, else: nil
    end

    assigns =
      assigns
      |> assign(grouped: grouped)
      |> assign(visible_categories: visible_categories)
      |> assign(section_weight: section_weight)
      |> assign(section_capacity: section_capacity)
      |> assign(section_calories: section_calories)

    ~H"""
    <main class="min-h-screen px-4 py-6 sm:px-6 lg:px-8">
      <div class="max-w-4xl mx-auto space-y-4">
        <header class="border-b border-base-300 pb-3">
          <h1 class="text-2xl font-bold">{@trip.name}</h1>
          <div :if={@trip.start_date || @trip.end_date} class="text-sm opacity-70 mt-1">
            <span :if={@trip.start_date}>{Calendar.strftime(@trip.start_date, "%b %-d, %Y")}</span>
            <span :if={@trip.start_date && @trip.end_date} class="mx-1">→</span>
            <span :if={@trip.end_date}>{Calendar.strftime(@trip.end_date, "%b %-d, %Y")}</span>
          </div>
          <p class="text-xs opacity-50 mt-2">Read-only · shared via packheavy</p>
        </header>

        <% report = @trip.validation_report || %{totals: %{}} %>
        <% totals = report.totals || %{} %>
        <% calories = Map.get(totals, :calories, 0) %>
        <% food_g = Map.get(totals, :food_weight_g, 0) %>
        <% days = TripShow.trip_days(@trip) %>
        <% kcal_per_g =
          if food_g > 0,
            do: :erlang.float_to_binary(calories / food_g, decimals: 1),
            else: nil %>

        <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
          <div class="space-y-1">
            <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Weight breakdown</h3>
            <TripShow.weight_breakdown trip={@trip} />
          </div>

          <div class="space-y-1">
            <h3 class="text-xs font-semibold opacity-70 uppercase tracking-wide">Resources</h3>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-2">
              <div class="card bg-base-200 p-3">
                <div class="text-xs opacity-70">Calories</div>
                <div class="text-lg font-semibold tabular-nums">{calories} kcal</div>
                <div :if={days} class="text-xs opacity-50">
                  ~{div(calories, max(days, 1))} kcal/day · {days} day(s)
                </div>
                <div :if={kcal_per_g} class="text-xs opacity-50">
                  avg {kcal_per_g} kcal/g across {food_g} g
                </div>
              </div>
              <div class="card bg-base-200 p-3">
                <div class="text-xs opacity-70">Carrying capacity</div>
                <div class="text-lg font-semibold tabular-nums">
                  {TripShow.format_capacity(Map.get(totals, :pack_volume_l, 0))} L
                </div>
                <div class="text-xs opacity-50">
                  + {Map.get(totals, :water_ml, 0)} ml water
                </div>
              </div>
              <div class="card bg-base-200 p-3">
                <div class="text-xs opacity-70">Power</div>
                <div class="text-lg font-semibold tabular-nums">{Map.get(totals, :power_mah, 0)} mAh</div>
              </div>
            </div>
          </div>
        </div>

        <%= if @trip.trip_items == [] do %>
          <p class="opacity-70 italic">No items on this trip.</p>
        <% else %>
          <div class="space-y-5">
            <section :for={{cat, label} <- @visible_categories}>
              <div class="flex justify-between items-baseline border-b border-success pb-0.5 mb-1">
                <h3 class="text-success text-xs font-bold uppercase tracking-wide">{label}</h3>
                <span class="text-success text-xs tabular-nums opacity-80">
                  <span :if={cap = @section_capacity.(cat)} class="mr-2">Σ {TripShow.format_capacity(cap)} L</span><span :if={kcal = @section_calories.(cat)} class="mr-2">Σ {kcal} kcal</span>{@section_weight.(cat)} g
                </span>
              </div>
              <ul class="divide-y divide-base-300">
                <li
                  :for={ti <- Map.get(@grouped, cat, [])}
                  class="flex items-center py-2 px-1 gap-2"
                >
                  <span class="flex-1 min-w-0 truncate text-sm">
                    <span :if={ti.item.brand} class="opacity-60 mr-1">{ti.item.brand}</span>
                    {ti.item.title}
                  </span>
                  <span :if={cap = TripShow.pack_capacity(ti)} class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                    {TripShow.format_capacity(cap)} L
                  </span>
                  <span :if={kcal = TripShow.food_calories(ti)} class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                    {kcal} kcal
                  </span>
                  <span class="opacity-60 text-xs tabular-nums text-right whitespace-nowrap">
                    <%= if ti.qty > 1 do %>
                      {ti.item.weight_g || 0} g × {ti.qty}
                    <% else %>
                      ×1
                    <% end %>
                  </span>
                  <span class="opacity-60 text-xs tabular-nums w-16 text-right">
                    {(ti.item.weight_g || 0) * ti.qty} g
                  </span>
                </li>
              </ul>
            </section>
          </div>
        <% end %>
      </div>
    </main>
    """
  end

  # Same canonical category order as TripLive.Show.category_order/0,
  # which is private there. Duplicated to keep the public view's
  # category labelling self-contained.
  defp category_order do
    [
      {:pack, "Packs"},
      {:shelter, "Shelter"},
      {:sleep, "Sleep"},
      {:clothing, "Clothing"},
      {:cooking, "Cooking"},
      {:water_container, "Water"},
      {:food, "Food"},
      {:electronic, "Electronics"},
      {:camera_lens, "Camera lenses"},
      {:power, "Powerbanks"},
      {:battery, "Batteries"},
      {:cable, "Cables"},
      {:hygiene, "Hygiene"},
      {:first_aid, "First aid"},
      {:tools, "Tools"},
      {:containers, "Containers"},
      {:other, "Other"}
    ]
  end
end
