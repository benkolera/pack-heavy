# Roundtrip smoke test for Packheavy.Backup.
#
# Run against a clean dev DB:
#
#     mix ecto.reset && mix run priv/scripts/backup_smoke.exs
#
# Verifies: export shape, FK remap (kit_items.item_id, item.category_data
# cable_type_id / battery_type_id), and that restore wipes pre-existing
# trips + items not in the backup.

require Ash.Query

alias Packheavy.{Backup, Inventory}

email = "backup-smoke@local"

user =
  case Packheavy.Accounts.User
       |> Ash.Query.filter(email == ^email)
       |> Ash.read_one(authorize?: false) do
    {:ok, %{} = u} ->
      u

    {:ok, nil} ->
      Packheavy.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: email,
          password: "password123",
          password_confirmation: "password123"
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
  end

# Clear any leftovers from a prior aborted run.
Packheavy.Backup.restore!(user, %{
  "version" => 1,
  "cable_types" => [],
  "battery_types" => [],
  "items" => [],
  "kits" => []
})

# --- Seed fixtures --------------------------------------------------------

# user_id isn't a public attribute on these resources — they use
# `change relate_actor(:user)` instead, so we pass `actor: user`.
opts = [actor: user, authorize?: false]

usbc = Ash.create!(Inventory.CableType, %{name: "USB-C"}, opts)
aa = Ash.create!(Inventory.BatteryType, %{name: "AA", rechargeable: false}, opts)

cable_item =
  Ash.create!(
    Inventory.Item,
    %{
      title: "USB-C Cable",
      weight_g: 30,
      category_data: %{"type" => "cable", "cable_type_id" => usbc.id}
    },
    opts
  )

battery_item =
  Ash.create!(
    Inventory.Item,
    %{
      title: "AA Battery",
      weight_g: 25,
      qty: 4,
      category_data: %{"type" => "battery", "battery_type_id" => aa.id}
    },
    opts
  )

_shelter_item =
  Ash.create!(
    Inventory.Item,
    %{title: "Tent", weight_g: 1500, category_data: %{"type" => "shelter"}},
    opts
  )

# Electronic with FK refs to BOTH cable and battery types — this used
# to silently lose its links on restore because remap_category only
# knew about the `:cable` and `:battery` variants.
phone_item =
  Ash.create!(
    Inventory.Item,
    %{
      title: "Phone",
      weight_g: 200,
      category_data: %{
        "type" => "electronic",
        "power_source" => "built_in",
        "charger_cable_type_id" => usbc.id,
        "battery_type_id" => aa.id
      }
    },
    opts
  )

_food_item =
  Ash.create!(
    Inventory.Item,
    %{
      title: "Trail mix",
      weight_g: 100,
      qty: 3,
      category_data: %{"type" => "food", "calories" => 500, "serving_label" => "100g"}
    },
    opts
  )

kit = Ash.create!(Inventory.Kit, %{name: "Day kit", description: nil}, opts)

Ash.create!(Inventory.KitItem, %{kit_id: kit.id, item_id: cable_item.id, qty: 1}, opts)
Ash.create!(Inventory.KitItem, %{kit_id: kit.id, item_id: battery_item.id, qty: 4}, opts)

# --- Export ---------------------------------------------------------------

backup = Backup.export(user)
encoded = Jason.encode!(backup, pretty: true)
IO.puts("Exported #{byte_size(encoded)} bytes")

original_counts = %{
  cable_types: length(backup["cable_types"]),
  battery_types: length(backup["battery_types"]),
  items: length(backup["items"]),
  kits: length(backup["kits"])
}

IO.inspect(original_counts, label: "exported counts")

# --- Add data that should NOT survive a restore ---------------------------

Ash.create!(
  Inventory.Item,
  %{title: "Junk", weight_g: 10, category_data: %{"type" => "other"}},
  opts
)

Ash.create!(Packheavy.Trips.Trip, %{name: "Should-be-wiped trip"}, opts)

# --- Restore --------------------------------------------------------------

# Round-trip through Jason to confirm the encoded form is what gets restored
restored_data = Jason.decode!(encoded)
summary = Backup.restore!(user, restored_data)
IO.inspect(summary, label: "restore summary")

# --- Verify ---------------------------------------------------------------

scoped = fn resource ->
  resource
  |> Ash.Query.filter(user_id == ^user.id)
  |> Ash.read!(actor: user)
end

post_items = scoped.(Inventory.Item)
post_cable_types = scoped.(Inventory.CableType)
post_battery_types = scoped.(Inventory.BatteryType)
post_trips = scoped.(Packheavy.Trips.Trip)

post_kits =
  Inventory.Kit
  |> Ash.Query.filter(user_id == ^user.id)
  |> Ash.Query.load(:kit_items)
  |> Ash.read!(actor: user)

post_counts = %{
  cable_types: length(post_cable_types),
  battery_types: length(post_battery_types),
  items: length(post_items),
  kits: length(post_kits),
  trips: length(post_trips)
}

IO.inspect(post_counts, label: "post-restore counts")

unless post_counts.cable_types == original_counts.cable_types and
         post_counts.battery_types == original_counts.battery_types and
         post_counts.items == original_counts.items and
         post_counts.kits == original_counts.kits and
         post_counts.trips == 0 do
  raise "Restore counts don't match the export"
end

# Verify FK remapping: the cable item's cable_type_id should match
# one of the new cable_types' id (not the original UUID).
cable_after =
  Enum.find(post_items, fn i ->
    cd = i.category_data
    val = if is_struct(cd, Ash.Union), do: cd.value, else: cd
    is_struct(val, Inventory.Item.Cable)
  end)

new_cable_type_ids = Enum.map(post_cable_types, & &1.id)
referenced_id =
  case cable_after.category_data do
    %Ash.Union{value: %Inventory.Item.Cable{cable_type_id: id}} -> id
    %Inventory.Item.Cable{cable_type_id: id} -> id
  end

unless referenced_id in new_cable_type_ids do
  raise "cable_item.category_data.cable_type_id did not get remapped"
end

# Verify Electronic's nested FK refs (charger_cable_type_id +
# battery_type_id) — the bug that prompted this test.
electronic_after =
  Enum.find(post_items, fn i ->
    cd = i.category_data
    val = if is_struct(cd, Ash.Union), do: cd.value, else: cd
    is_struct(val, Inventory.Item.Electronic)
  end)

new_battery_type_ids = Enum.map(post_battery_types, & &1.id)

elec_val =
  case electronic_after.category_data do
    %Ash.Union{value: v} -> v
    v -> v
  end

unless elec_val.charger_cable_type_id in new_cable_type_ids do
  raise "electronic.charger_cable_type_id did not get remapped (got #{inspect(elec_val.charger_cable_type_id)})"
end

unless elec_val.battery_type_id in new_battery_type_ids do
  raise "electronic.battery_type_id did not get remapped (got #{inspect(elec_val.battery_type_id)})"
end

# Verify kit_item FK remap
[kit_after] = post_kits
new_item_ids = Enum.map(post_items, & &1.id)
ki_item_ids = Enum.map(kit_after.kit_items, & &1.item_id)

unless Enum.all?(ki_item_ids, &(&1 in new_item_ids)) do
  raise "kit_items.item_id remap failed"
end

IO.puts("\n✓ Backup round-trip OK")
