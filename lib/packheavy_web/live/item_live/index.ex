defmodule PackheavyWeb.ItemLive.Index do
  use PackheavyWeb, :live_view

  alias Packheavy.Inventory
  alias Packheavy.Inventory.Item

  @categories [
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
    {:first_aid, "First aid"},
    {:hygiene, "Hygiene"},
    {:containers, "Containers"},
    {:tools, "Tools"},
    {:other, "Other"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    cable_types = Inventory.list_cable_types!(actor: user)
    battery_types = Inventory.list_battery_types!(actor: user)

    {:ok,
     socket
     |> assign(
       page_title: "Packheavy: Item Inventory",
       categories: @categories,
       cable_types: cable_types,
       battery_types: battery_types
     )
     |> reload()}
  end

  defp reload(socket) do
    items = Inventory.list_items!(actor: socket.assigns.current_user)

    grouped =
      items
      |> Enum.sort_by(fn item ->
        String.downcase("#{item.brand || ""} #{item.title}")
      end)
      |> Enum.group_by(fn item -> item.category_data.type end)

    brands =
      items
      |> Enum.map(& &1.brand)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort_by(&String.downcase/1)

    socket
    |> assign(:items, items)
    |> assign(:grouped, grouped)
    |> assign(:brands, brands)
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:item, nil)
    |> assign(:form, nil)
    |> assign(:category, nil)
  end

  defp apply_action(socket, :new, params) do
    category = (params["category"] || "electronic") |> String.to_existing_atom()
    socket
    |> assign(:item, nil)
    |> assign(:category, category)
    |> assign(:form, build_create_form(socket.assigns.current_user, category))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    item = Inventory.get_item!(id, actor: socket.assigns.current_user)
    category = item.category_data.type

    socket
    |> assign(:item, item)
    |> assign(:category, category)
    |> assign(:form, build_update_form(item, socket.assigns.current_user))
  end

  defp build_create_form(user, category) do
    AshPhoenix.Form.for_create(Item, :create,
      actor: user,
      forms: [
        category_data: [
          type: :single,
          resource: variant_module(category),
          create_action: :create,
          update_action: :update
        ]
      ]
    )
    |> AshPhoenix.Form.add_form([:category_data], params: %{"type" => to_string(category)})
    |> to_form()
  end

  defp build_update_form(item, user) do
    category = item.category_data.type

    AshPhoenix.Form.for_update(item, :update,
      actor: user,
      forms: [
        category_data: [
          type: :single,
          resource: variant_module(category),
          create_action: :create,
          update_action: :update,
          data: item.category_data
        ]
      ]
    )
    |> to_form()
  end

  defp variant_module(:electronic), do: Item.Electronic
  defp variant_module(:camera_lens), do: Item.CameraLens
  defp variant_module(:water_container), do: Item.Water
  defp variant_module(:food), do: Item.Food
  defp variant_module(:pack), do: Item.Pack
  defp variant_module(:power), do: Item.Power
  defp variant_module(:battery), do: Item.Battery
  defp variant_module(:cable), do: Item.Cable
  defp variant_module(:shelter), do: Item.Shelter
  defp variant_module(:sleep), do: Item.Sleep
  defp variant_module(:cooking), do: Item.Cooking
  defp variant_module(:first_aid), do: Item.FirstAid
  defp variant_module(:hygiene), do: Item.Hygiene
  defp variant_module(:clothing), do: Item.Clothing
  defp variant_module(:containers), do: Item.Containers
  defp variant_module(:tools), do: Item.Tools
  defp variant_module(:other), do: Item.Other

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> reload()
         |> push_patch(to: ~p"/items")}

      {:error, form} ->
        {:noreply,
         socket
         |> put_flash(:error, form_error_summary(form))
         |> assign(:form, form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    item = Inventory.get_item!(id, actor: socket.assigns.current_user)
    Ash.destroy!(item, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Deleted.") |> reload()}
  end

  defp form_error_summary(form) do
    # form is a Phoenix.HTML.Form whose .errors field is already a flat
    # keyword list of {field, {msg, opts}} tuples populated from the
    # underlying Ash changeset by AshPhoenix.
    case form.errors do
      [] ->
        "Could not save — check the form."

      errors ->
        errors
        |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
        |> Enum.join(" · ")
    end
  end

  defp category_label(nil), do: ""

  defp category_label(category) do
    case Enum.find(@categories, fn {c, _} -> c == category end) do
      {_, label} -> label
      nil -> to_string(category)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-2xl font-bold">Items</h1>

      <dialog class="modal" open={!is_nil(@form)}>
        <div class="modal-box max-w-2xl">
          <h2 class="text-lg font-semibold mb-4">
            <%= if @item, do: "Edit item", else: "New #{category_label(@category)}" %>
          </h2>

          <%= if @form do %>
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <.field label="Brand (optional)">
                  <input type="text" name="form[brand]" value={@form[:brand].value} class="input input-bordered w-full" placeholder="e.g. Savotta" list="brands-list" autocomplete="off" />
                  <datalist id="brands-list">
                    <option :for={b <- @brands} value={b} />
                  </datalist>
                </.field>
                <div class="sm:col-span-2">
                  <.field label="Title">
                    <input type="text" name="form[title]" value={@form[:title].value} class="input input-bordered w-full" required autofocus />
                  </.field>
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <.field label="Weight (g)">
                  <input type="number" name="form[weight_g]" value={@form[:weight_g].value} class="input input-bordered w-full" min="0" />
                </.field>
                <.field label="Qty">
                  <input type="number" name="form[qty]" value={@form[:qty].value} class="input input-bordered w-full" min="0" />
                </.field>
              </div>

              <.field label="Notes">
                <textarea name="form[notes]" class="textarea textarea-bordered w-full" rows="2">{@form[:notes].value}</textarea>
              </.field>

              <fieldset class="border border-base-300 p-4 rounded space-y-3">
                <legend class="px-2 text-sm font-semibold opacity-70">{category_label(@category)} details</legend>
                <.inputs_for :let={cf} field={@form[:category_data]}>
                  <input type="hidden" name={"#{cf.name}[type]"} value={to_string(@category)} />
                  <.category_fields category={@category} cf={cf} cable_types={@cable_types} battery_types={@battery_types} />
                </.inputs_for>
              </fieldset>

              <div class="modal-action pt-2">
                <.link patch={~p"/items"} class="btn btn-ghost">Cancel</.link>
                <button class="btn btn-primary">Save</button>
              </div>
            </.form>
          <% end %>
        </div>
        <.link patch={~p"/items"} class="modal-backdrop">close</.link>
      </dialog>

      <div class="space-y-6">
        <section :for={{cat, label} <- @categories}>
          <div class="flex justify-between items-center border-b-2 border-success pb-1 mb-1 gap-2">
            <h2 class="text-success font-bold uppercase tracking-wide text-sm">{label}</h2>
            <span :if={summary = category_summary(cat, Map.get(@grouped, cat, []))} class="text-success text-xs tabular-nums opacity-80 ml-auto">{summary}</span>
            <.link patch={~p"/items/new?category=#{cat}"} class="no-print text-success text-xl leading-none" title={"Add #{label}"}>+</.link>
          </div>
          <%= case Map.get(@grouped, cat, []) do %>
            <% [] -> %>
              <p class="text-sm opacity-50 italic px-2 py-2">No {String.downcase(label)} items yet.</p>
            <% items -> %>
              <ul class="divide-y divide-base-300">
                <li :for={item <- items} class="flex items-center py-3 group hover:bg-base-200 px-1 sm:px-2 rounded gap-1 sm:gap-2">
                  <.link patch={~p"/items/#{item.id}/edit"} class="flex-1 min-w-0 text-left leading-tight">
                    <div class="truncate">
                      <span :if={item.brand} class="opacity-60 mr-1 inline-block max-w-[7rem] sm:max-w-none truncate align-bottom">{item.brand}</span>{item.title}
                      <span :if={item.qty != 1} class="opacity-60 ml-1">× {item.qty}</span>
                    </div>
                    <% extra = category_extra(item, @battery_types) %>
                    <% extra2 = category_extra_secondary(item) %>
                    <div :if={extra || extra2} class="text-xs opacity-50 tabular-nums sm:hidden">
                      {[extra, extra2] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
                    </div>
                  </.link>
                  <span class="opacity-60 text-sm tabular-nums text-right w-16 shrink-0 hidden sm:inline">{category_extra(item, @battery_types)}</span>
                  <span class="opacity-60 text-sm tabular-nums text-right w-20 shrink-0 hidden sm:inline">{category_extra_secondary(item)}</span>
                  <span class="opacity-60 tabular-nums text-right w-20 shrink-0">{format_weight(item.weight_g)}</span>
                  <span class="w-10 shrink-0 flex justify-end items-center gap-1">
                    <button phx-click="delete" phx-value-id={item.id} data-confirm={"Delete #{item.title}?"} class="opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs">×</button>
                    <.link patch={~p"/items/#{item.id}/edit"} class="no-print opacity-30 group-hover:opacity-70">›</.link>
                  </span>
                </li>
              </ul>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp format_weight(grams) when is_integer(grams), do: "#{grams}g"
  defp format_weight(_), do: "—"

  defp category_extra(%{category_data: %Ash.Union{value: cd}} = item, battery_types),
    do: extra_for(cd, item, battery_types)

  defp category_extra(_, _), do: nil

  defp extra_for(%Packheavy.Inventory.Item.Pack{volume_l: v}, _item, _) when not is_nil(v) do
    "#{format_volume(v)} L"
  end

  defp extra_for(%Packheavy.Inventory.Item.Water{capacity_ml: ml}, _item, _) when not is_nil(ml) do
    if ml >= 1000, do: "#{format_volume(ml / 1000)} L", else: "#{ml} ml"
  end

  defp extra_for(%Packheavy.Inventory.Item.Power{capacity_mah: mah}, _item, _) when not is_nil(mah) do
    "#{mah} mAh"
  end

  defp extra_for(
         %Packheavy.Inventory.Item.CameraLens{
           focal_length_min: fmin,
           focal_length_max: fmax,
           aperture_wide: aw,
           aperture_tele: at
         },
         _item,
         _
       )
       when not is_nil(fmin) and not is_nil(fmax) do
    fl = if fmin == fmax, do: "#{fmin}mm", else: "#{fmin}-#{fmax}mm"

    ap =
      cond do
        is_nil(aw) and is_nil(at) -> nil
        is_nil(at) or aw == at -> "f/#{format_volume(aw)}"
        true -> "f/#{format_volume(aw)}-#{format_volume(at)}"
      end

    if ap, do: "#{fl} #{ap}", else: fl
  end

  defp extra_for(%Packheavy.Inventory.Item.Food{calories: c}, _item, _) when not is_nil(c) do
    "#{c} kcal"
  end

  defp extra_for(
         %Packheavy.Inventory.Item.Battery{battery_type_id: bt_id},
         _item,
         battery_types
       )
       when not is_nil(bt_id) do
    Enum.find_value(battery_types, "?", fn bt -> if bt.id == bt_id, do: bt.name end)
  end

  defp extra_for(_, _, _), do: nil

  defp category_extra_secondary(%{
         category_data: %Ash.Union{value: %Packheavy.Inventory.Item.Food{calories: c}},
         weight_g: w
       })
       when is_integer(c) and is_integer(w) and w > 0 do
    "#{:erlang.float_to_binary(c / w, decimals: 1)} kcal/g"
  end

  defp category_extra_secondary(_), do: nil

  defp category_summary(:pack, items) do
    total =
      items
      |> Enum.map(fn item ->
        case item.category_data do
          %Ash.Union{value: %Packheavy.Inventory.Item.Pack{volume_l: v}} when is_number(v) ->
            v * (item.qty || 1)

          _ ->
            0
        end
      end)
      |> Enum.sum()

    if total > 0, do: "Σ #{format_volume(total)} L", else: nil
  end

  defp category_summary(_, _), do: nil

  defp format_volume(v) when is_float(v) do
    if v == Float.round(v), do: Integer.to_string(trunc(v)), else: :erlang.float_to_binary(v, decimals: 1)
  end

  defp format_volume(v), do: to_string(v)

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium mb-1">{@label}</label>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :category, :atom, required: true
  attr :cf, :any, required: true
  attr :cable_types, :list, required: true
  attr :battery_types, :list, required: true

  defp category_fields(%{category: :electronic} = assigns) do
    power_source = to_string(assigns.cf[:power_source].value || "built_in")
    assigns = assign(assigns, :power_source, power_source)

    ~H"""
    <.field label="Power source">
      <select name={"#{@cf.name}[power_source]"} class="select select-bordered w-full">
        <option value="built_in" selected={@power_source == "built_in"}>Built-in rechargeable battery</option>
        <option value="batteries" selected={@power_source == "batteries"}>Replaceable batteries</option>
      </select>
    </.field>

    <%= if @power_source == "built_in" do %>
      <.field label="Charger cable type">
        <select name={"#{@cf.name}[charger_cable_type_id]"} class="select select-bordered w-full">
          <option value="">—</option>
          <option :for={ct <- @cable_types} value={ct.id} selected={to_string(@cf[:charger_cable_type_id].value) == ct.id}>{ct.name}</option>
        </select>
      </.field>
    <% else %>
      <div class="grid grid-cols-2 gap-3">
        <.field label="Battery type">
          <select name={"#{@cf.name}[battery_type_id]"} class="select select-bordered w-full">
            <option value="">—</option>
            <option :for={bt <- @battery_types} value={bt.id} selected={to_string(@cf[:battery_type_id].value) == bt.id}>
              {bt.name}<%= if bt.rechargeable, do: " (rechargeable)" %>
            </option>
          </select>
        </.field>
        <.field label="How many it takes">
          <input type="number" name={"#{@cf.name}[battery_count]"} value={@cf[:battery_count].value} class="input input-bordered w-full" min="0" />
        </.field>
      </div>
    <% end %>
    """
  end

  defp category_fields(%{category: :water_container} = assigns) do
    ~H"""
    <.field label="Capacity (ml)">
      <input type="number" name={"#{@cf.name}[capacity_ml]"} value={@cf[:capacity_ml].value} class="input input-bordered w-full" min="0" />
    </.field>
    """
  end

  defp category_fields(%{category: :food} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <.field label="kcal per serving">
        <input type="number" name={"#{@cf.name}[calories]"} value={@cf[:calories].value} class="input input-bordered w-full" min="0" />
      </.field>
      <.field label="Serving label">
        <input type="text" name={"#{@cf.name}[serving_label]"} value={@cf[:serving_label].value} class="input input-bordered w-full" placeholder="e.g. bar" />
      </.field>
    </div>
    """
  end

  defp category_fields(%{category: :pack} = assigns) do
    ~H"""
    <.field label="Volume (L)">
      <input type="number" step="0.1" name={"#{@cf.name}[volume_l]"} value={@cf[:volume_l].value} class="input input-bordered w-full" min="0" />
    </.field>
    """
  end

  defp category_fields(%{category: :power} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <.field label="Capacity (mAh)">
        <input type="number" name={"#{@cf.name}[capacity_mah]"} value={@cf[:capacity_mah].value} class="input input-bordered w-full" min="0" />
      </.field>
      <.field label="USB ports">
        <input type="number" name={"#{@cf.name}[usb_ports]"} value={@cf[:usb_ports].value} class="input input-bordered w-full" min="0" />
      </.field>
    </div>
    """
  end

  defp category_fields(%{category: :camera_lens} = assigns) do
    kind = to_string(assigns.cf[:kind].value || "prime")
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <.field label="Type">
      <select name={"#{@cf.name}[kind]"} class="select select-bordered w-full">
        <option value="prime" selected={@kind == "prime"}>Prime</option>
        <option value="zoom" selected={@kind == "zoom"}>Zoom</option>
      </select>
    </.field>

    <%= if @kind == "prime" do %>
      <div class="grid grid-cols-2 gap-3">
        <.field label="Focal length (mm)">
          <input type="number" name={"#{@cf.name}[focal_length_min]"} value={@cf[:focal_length_min].value} class="input input-bordered w-full" min="1" placeholder="50" />
        </.field>
        <.field label="Aperture (f/)">
          <input type="number" step="0.1" name={"#{@cf.name}[aperture_wide]"} value={@cf[:aperture_wide].value} class="input input-bordered w-full" min="0.5" placeholder="1.8" />
        </.field>
      </div>
    <% else %>
      <div class="grid grid-cols-2 gap-3">
        <.field label="Focal length (mm)">
          <div class="flex gap-2 items-center">
            <input type="number" name={"#{@cf.name}[focal_length_min]"} value={@cf[:focal_length_min].value} class="input input-bordered w-full" min="1" placeholder="24" />
            <span class="opacity-60">to</span>
            <input type="number" name={"#{@cf.name}[focal_length_max]"} value={@cf[:focal_length_max].value} class="input input-bordered w-full" min="1" placeholder="70" />
          </div>
        </.field>
        <.field label="Max aperture (f/)">
          <div class="flex gap-2 items-center">
            <input type="number" step="0.1" name={"#{@cf.name}[aperture_wide]"} value={@cf[:aperture_wide].value} class="input input-bordered w-full" min="0.5" placeholder="2.8" title="At wide end" />
            <span class="opacity-60">to</span>
            <input type="number" step="0.1" name={"#{@cf.name}[aperture_tele]"} value={@cf[:aperture_tele].value} class="input input-bordered w-full" min="0.5" placeholder="2.8" title="At telephoto end" />
          </div>
        </.field>
      </div>
      <p class="text-xs opacity-50">If the aperture is constant (e.g. f/2.8 across the zoom), enter the same value in both.</p>
    <% end %>
    """
  end

  defp category_fields(%{category: :battery} = assigns) do
    ~H"""
    <.field label="Battery type">
      <select name={"#{@cf.name}[battery_type_id]"} class="select select-bordered w-full" required>
        <option value="">—</option>
        <option :for={bt <- @battery_types} value={bt.id} selected={to_string(@cf[:battery_type_id].value) == bt.id}>
          {bt.name}<%= if bt.rechargeable, do: " (rechargeable)" %>
        </option>
      </select>
    </.field>
    """
  end

  defp category_fields(%{category: :cable} = assigns) do
    ~H"""
    <.field label="Cable type">
      <select name={"#{@cf.name}[cable_type_id]"} class="select select-bordered w-full">
        <option value="">—</option>
        <option :for={ct <- @cable_types} value={ct.id} selected={to_string(@cf[:cable_type_id].value) == ct.id}>{ct.name}</option>
      </select>
    </.field>
    """
  end

  # Catch-all for simple categories (other, shelter, sleep, cooking,
  # first_aid, hygiene, clothing, containers, tools): only the type
  # discriminator, no extra fields.
  defp category_fields(assigns) do
    ~H"""
    <p class="text-sm opacity-60 italic">No extra fields for this category.</p>
    """
  end
end
