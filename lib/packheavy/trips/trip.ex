defmodule Packheavy.Trips.Trip do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "trips"
    repo Packheavy.Repo
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :start_packing, from: :draft, to: :packing
      transition :reopen, from: :packing, to: :draft
      transition :complete, from: :packing, to: :complete
    end
  end

  actions do
    defaults [:read, :destroy, update: [:name, :start_date, :end_date]]

    create :create do
      primary? true
      accept [:name, :start_date, :end_date]
      change relate_actor(:user)
    end

    update :start_packing do
      change transition_state(:packing)
    end

    update :reopen do
      change transition_state(:draft)
    end

    update :complete do
      require_atomic? false

      change transition_state(:complete)

      change fn changeset, _ctx ->
        Ash.Changeset.after_action(changeset, fn _cs, trip ->
          trip
          |> Ash.load!(
            [trip_items: [:qty, item: [:id, :title, :qty, :category_data]]],
            authorize?: false
          )
          |> Map.get(:trip_items)
          |> Enum.each(fn ti ->
            cd = ti.item && ti.item.category_data

            food? =
              match?(%Ash.Union{value: %Packheavy.Inventory.Item.Food{}}, cd) or
                match?(%Packheavy.Inventory.Item.Food{}, cd)

            if food? do
              ti.item
              |> Ash.Changeset.for_update(:decrement_qty, %{amount: ti.qty || 1})
              |> Ash.update!(authorize?: false)
            end
          end)

          {:ok, trip}
        end)
      end
    end

    update :add_kit do
      description "Expand a Kit's items into TripItems and record a TripKit breadcrumb"
      argument :kit_id, :uuid, allow_nil?: false
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.after_action(changeset, fn _cs, trip ->
          kit_id = Ash.Changeset.get_argument(changeset, :kit_id)

          kit =
            Packheavy.Inventory.Kit
            |> Ash.get!(kit_id, load: [kit_items: []])

          Ash.create!(
            Packheavy.Trips.TripKit,
            %{trip_id: trip.id, kit_id: kit_id},
            upsert?: true,
            upsert_identity: :unique_trip_kit
          )

          require Ash.Query

          Enum.each(kit.kit_items, fn ki ->
            item = Ash.get!(Packheavy.Inventory.Item, ki.item_id, authorize?: false)
            owned = item.qty || 0

            already_on_trip =
              Packheavy.Trips.TripItem
              |> Ash.Query.filter(trip_id == ^trip.id and item_id == ^ki.item_id)
              |> Ash.read!(authorize?: false)
              |> Enum.map(& &1.qty)
              |> Enum.sum()

            available = max(owned - already_on_trip, 0)
            qty = min(ki.qty, available)

            if qty > 0 do
              Ash.create!(
                Packheavy.Trips.TripItem,
                %{
                  trip_id: trip.id,
                  item_id: ki.item_id,
                  qty: qty,
                  source: :kit,
                  source_kit_id: kit_id
                },
                authorize?: false
              )
            end
          end)

          {:ok, trip}
        end)
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :start_date, :date, public?: true
    attribute :end_date, :date, public?: true
    timestamps()
  end

  relationships do
    belongs_to :user, Packheavy.Accounts.User, allow_nil?: false
    has_many :trip_items, Packheavy.Trips.TripItem
    has_many :trip_kits, Packheavy.Trips.TripKit
  end

  calculations do
    calculate :validation_report, :map, Packheavy.Trips.Calculations.ValidationReport
  end
end
