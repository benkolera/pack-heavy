require Ash.Query

{:ok, user} =
  Packheavy.Accounts.User
  |> Ash.Changeset.for_create(
    :register_with_password,
    %{
      email: "ben@local",
      password: "password123",
      password_confirmation: "password123"
    },
    authorize?: false
  )
  |> Ash.create(authorize?: false)

IO.inspect(user.id, label: "created user")

cable_type =
  Ash.create!(Packheavy.Inventory.CableType, %{name: "USB-C", user_id: user.id}, authorize?: false)

phone =
  Ash.create!(
    Packheavy.Inventory.Item,
    %{
      title: "Phone",
      weight_g: 200,
      user_id: user.id,
      category_data: %{
        "type" => "electronic",
        "rechargeable" => true,
        "charger_cable_type_id" => cable_type.id
      }
    },
    authorize?: false
  )

IO.inspect(phone.category_data, label: "phone.category_data")

usbc_cable =
  Ash.create!(
    Packheavy.Inventory.Item,
    %{
      title: "USB-C Cable",
      weight_g: 30,
      user_id: user.id,
      category_data: %{"type" => "cable", "cable_type_id" => cable_type.id}
    },
    authorize?: false
  )

food =
  Ash.create!(
    Packheavy.Inventory.Item,
    %{
      title: "Trail mix",
      weight_g: 100,
      user_id: user.id,
      category_data: %{"type" => "food", "calories" => 500, "qty" => 3}
    },
    authorize?: false
  )

trip =
  Ash.create!(Packheavy.Trips.Trip, %{name: "Test Hike", user_id: user.id}, authorize?: false)

IO.inspect(trip.state, label: "trip state")

Ash.create!(Packheavy.Trips.TripItem, %{trip_id: trip.id, item_id: phone.id, qty: 1},
  authorize?: false
)

Ash.create!(Packheavy.Trips.TripItem, %{trip_id: trip.id, item_id: usbc_cable.id, qty: 1},
  authorize?: false
)

Ash.create!(Packheavy.Trips.TripItem, %{trip_id: trip.id, item_id: food.id, qty: 2},
  authorize?: false
)

trip =
  try do
    Ash.load!(trip, [:validation_report], authorize?: false)
  rescue
    e ->
      IO.inspect(e, label: "load error", pretty: true, structs: false)
      reraise e, __STACKTRACE__
  end

IO.inspect(trip.validation_report, label: "validation_report (with cable)", pretty: true)

# Now remove the cable and re-check — should error
ti =
  Packheavy.Trips.TripItem
  |> Ash.Query.filter(trip_id == ^trip.id and item_id == ^usbc_cable.id)
  |> Ash.read_one!(authorize?: false)

Ash.destroy!(ti, authorize?: false)

trip2 = Ash.load!(trip, [:validation_report], authorize?: false)
IO.inspect(trip2.validation_report, label: "validation_report (no cable)", pretty: true)

# Test Kit + add_kit expansion
kit =
  Ash.create!(Packheavy.Inventory.Kit, %{name: "Cook Kit", user_id: user.id}, authorize?: false)

stove =
  Ash.create!(
    Packheavy.Inventory.Item,
    %{
      title: "Stove",
      weight_g: 80,
      user_id: user.id,
      category_data: %{"type" => "other", "subcategory" => "cooking"}
    },
    authorize?: false
  )

Ash.create!(
  Packheavy.Inventory.KitItem,
  %{kit_id: kit.id, item_id: stove.id, qty: 1},
  authorize?: false
)

trip3 =
  Ash.create!(Packheavy.Trips.Trip, %{name: "Kit Test", user_id: user.id}, authorize?: false)

Packheavy.Trips.add_kit(trip3, kit.id, authorize?: false)

trip3 = Ash.load!(trip3, [trip_items: [:item], trip_kits: []], authorize?: false)

IO.inspect(Enum.map(trip3.trip_items, &{&1.item.title, &1.source, &1.qty}),
  label: "trip3 items after add_kit"
)

IO.inspect(length(trip3.trip_kits), label: "trip_kits count")

# Test complete action decrementing food qty
trip4 =
  Ash.create!(Packheavy.Trips.Trip, %{name: "Eat Hike", user_id: user.id}, authorize?: false)

food2 =
  Ash.create!(
    Packheavy.Inventory.Item,
    %{
      title: "Bar",
      weight_g: 50,
      user_id: user.id,
      category_data: %{"type" => "food", "calories" => 300, "qty" => 5}
    },
    authorize?: false
  )

Ash.create!(Packheavy.Trips.TripItem, %{trip_id: trip4.id, item_id: food2.id, qty: 3},
  authorize?: false
)

trip4 =
  trip4
  |> Ash.Changeset.for_update(:start_packing)
  |> Ash.update!(authorize?: false)

IO.inspect(trip4.state, label: "after start_packing")

result =
  trip4
  |> Ash.Changeset.for_update(:complete)
  |> Ash.update(authorize?: false)

IO.inspect(result, label: "complete result", pretty: true, structs: false)

trip4_reloaded = Ash.get!(Packheavy.Trips.Trip, trip4.id, authorize?: false)
IO.inspect(trip4_reloaded.state, label: "trip4 state after complete")

food2_after = Ash.get!(Packheavy.Inventory.Item, food2.id, authorize?: false)
IO.inspect(food2_after.category_data, label: "food after complete (qty should be 2)", pretty: true)
