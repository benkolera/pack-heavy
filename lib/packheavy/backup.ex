defmodule Packheavy.Backup do
  @moduledoc """
  Export / restore the user's gear inventory: cable types, battery types,
  items (with their polymorphic category_data), and kits + kit_items.

  Trips are deliberately excluded from export (they're packing state, not
  gear) but ARE wiped on restore — see `restore!/2`.
  """

  alias Packheavy.{Inventory, Repo}
  alias Packheavy.Inventory.{BatteryType, CableType, Item, Kit}
  alias Packheavy.Trips.Trip
  require Ash.Query

  @version 1

  # The resources now have actor-scoped policies, so `actor: user`
  # alone would scope reads. The explicit user_id filter stays as
  # defense-in-depth — if a future refactor loosened a policy, the
  # filter still prevents this module from reading other users' rows.
  defp scoped_read!(resource, user) do
    resource
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(actor: user)
  end

  # --- Export ---------------------------------------------------------------

  @doc """
  Returns a JSON-encodable map of all of `user`'s gear data.
  """
  def export(user) do
    cable_types = scoped_read!(CableType, user)
    battery_types = scoped_read!(BatteryType, user)
    items = scoped_read!(Item, user)

    kits =
      Kit
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.Query.load(:kit_items)
      |> Ash.read!(actor: user)

    %{
      "version" => @version,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "cable_types" => Enum.map(cable_types, &dump_cable_type/1),
      "battery_types" => Enum.map(battery_types, &dump_battery_type/1),
      "items" => Enum.map(items, &dump_item/1),
      "kits" => Enum.map(kits, &dump_kit/1)
    }
  end

  defp dump_cable_type(c), do: %{"id" => c.id, "name" => c.name}

  defp dump_battery_type(b),
    do: %{"id" => b.id, "name" => b.name, "rechargeable" => b.rechargeable}

  defp dump_item(i) do
    %{
      "id" => i.id,
      "title" => i.title,
      "brand" => i.brand,
      "weight_g" => i.weight_g,
      "qty" => i.qty,
      "notes" => i.notes,
      "category_data" => dump_category(i.category_data)
    }
  end

  # category_data is wrapped in %Ash.Union{} when loaded.
  defp dump_category(%Ash.Union{value: variant}), do: dump_variant(variant)
  defp dump_category(variant) when is_struct(variant), do: dump_variant(variant)

  defp dump_variant(variant) do
    variant
    |> Map.from_struct()
    |> Map.drop([:__meta__, :calculations, :aggregates])
    |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), jsonable(v)} end)
  end

  # Atom values (e.g. discriminator :cable) → strings; pass everything
  # else through. nil/booleans stay as-is.
  defp jsonable(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp jsonable(v), do: v

  defp dump_kit(k) do
    %{
      "id" => k.id,
      "name" => k.name,
      "description" => k.description,
      "kit_items" => Enum.map(k.kit_items, &dump_kit_item/1)
    }
  end

  defp dump_kit_item(ki), do: %{"item_id" => ki.item_id, "qty" => ki.qty}

  # --- Restore --------------------------------------------------------------

  @doc """
  Wipes ALL of `user`'s data (trips, kits, items, cable types, battery
  types) and recreates inventory + kits from `data`. Atomic: a parse
  failure rolls back the whole thing.

  Foreign keys inside the export (kit_items.item_id, item.category_data
  cable_type_id / battery_type_id) are remapped from old UUIDs to the
  newly-minted UUIDs as records get inserted.
  """
  def restore!(user, data) when is_map(data) do
    validate!(data)

    {:ok, summary} =
      Repo.transaction(fn ->
        wipe!(user)
        seed!(user, data)
      end)

    summary
  end

  defp validate!(%{"version" => @version} = data) do
    for key <- ["cable_types", "battery_types", "items", "kits"] do
      unless Map.has_key?(data, key), do: raise("Backup is missing key: #{key}")
      unless is_list(data[key]), do: raise("Backup field #{key} must be a list")
    end

    :ok
  end

  defp validate!(%{"version" => v}),
    do: raise("Unsupported backup version: #{inspect(v)} (this build supports v#{@version})")

  defp validate!(_), do: raise("Invalid backup file (no version field)")

  defp wipe!(user) do
    # FK cascades clean up the join tables for us:
    #   Trip → trip_items, trip_kits
    #   Kit  → kit_items, leftover trip_kits
    #   Item → kit_items, leftover trip_items
    destroy_all!(Trip, user)
    destroy_all!(Kit, user)
    destroy_all!(Item, user)
    destroy_all!(CableType, user)
    destroy_all!(BatteryType, user)
  end

  defp destroy_all!(resource, user) do
    resource
    |> scoped_read!(user)
    |> Enum.each(&Ash.destroy!(&1, actor: user))
  end

  defp seed!(user, data) do
    cable_map = seed_cable_types!(user, data["cable_types"])
    battery_map = seed_battery_types!(user, data["battery_types"])
    item_map = seed_items!(user, data["items"], cable_map, battery_map)
    seed_kits!(user, data["kits"], item_map)

    %{
      cable_types: map_size(cable_map),
      battery_types: map_size(battery_map),
      items: map_size(item_map),
      kits: length(data["kits"])
    }
  end

  defp seed_cable_types!(user, cable_types) do
    for %{"id" => old_id, "name" => name} <- cable_types, into: %{} do
      ct = Inventory.create_cable_type!(%{name: name}, actor: user)
      {old_id, ct.id}
    end
  end

  defp seed_battery_types!(user, battery_types) do
    for %{"id" => old_id} = bt <- battery_types, into: %{} do
      attrs = %{name: bt["name"], rechargeable: bt["rechargeable"] || false}
      record = Inventory.create_battery_type!(attrs, actor: user)
      {old_id, record.id}
    end
  end

  defp seed_items!(user, items, cable_map, battery_map) do
    for %{"id" => old_id} = item <- items, into: %{} do
      attrs = %{
        title: item["title"],
        brand: item["brand"],
        weight_g: item["weight_g"] || 0,
        qty: item["qty"] || 1,
        notes: item["notes"],
        category_data: remap_category(item["category_data"], cable_map, battery_map)
      }

      record = Inventory.create_item!(attrs, actor: user)
      {old_id, record.id}
    end
  end

  # Remap any field whose name ends in `_cable_type_id` or
  # `_battery_type_id` (with or without a prefix) to the newly-minted
  # UUID. Covers `cable.cable_type_id`, `battery.battery_type_id`, and
  # `electronic.charger_cable_type_id` / `electronic.battery_type_id`.
  # Future variants that add a `*_cable_type_id` or `*_battery_type_id`
  # field will be handled automatically.
  defp remap_category(c, cable_map, battery_map) when is_map(c) do
    Enum.into(c, %{}, fn
      {k, old_id} when is_binary(k) and is_binary(old_id) ->
        cond do
          String.ends_with?(k, "cable_type_id") and Map.has_key?(cable_map, old_id) ->
            {k, Map.fetch!(cable_map, old_id)}

          String.ends_with?(k, "battery_type_id") and Map.has_key?(battery_map, old_id) ->
            {k, Map.fetch!(battery_map, old_id)}

          true ->
            {k, old_id}
        end

      kv ->
        kv
    end)
  end

  defp seed_kits!(user, kits, item_map) do
    Enum.each(kits, fn kit ->
      record =
        Inventory.create_kit!(
          %{name: kit["name"], description: kit["description"]},
          actor: user
        )

      Enum.each(kit["kit_items"] || [], fn ki ->
        new_item_id = Map.fetch!(item_map, ki["item_id"])

        Inventory.add_kit_item!(
          %{kit_id: record.id, item_id: new_item_id, qty: ki["qty"] || 1},
          actor: user
        )
      end)
    end)
  end
end
