defmodule Packheavy.Trips.Trip do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
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

  # The public share endpoint is the only action accessible without an
  # actor. Its filter requires a non-nil share_token AND a match — no
  # enumeration possible. Every other action requires the actor to own
  # the trip (or, for create, just to be present — `relate_actor(:user)`
  # sets user_id from the actor itself).
  policies do
    bypass action(:read_by_share_token) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  actions do
    defaults [:read, :destroy, update: [:name, :start_date, :end_date]]

    create :create do
      primary? true
      accept [:name, :start_date, :end_date]
      change relate_actor(:user)
    end

    read :read_by_share_token do
      description "Public read of a trip via its opaque share token"
      argument :share_token, :string, allow_nil?: false
      get? true
      filter expr(share_token == ^arg(:share_token) and not is_nil(share_token))
    end

    update :enable_sharing do
      description "Generate (if absent) a URL-safe random share token"
      require_atomic? false

      change fn changeset, _ctx ->
        case Ash.Changeset.get_attribute(changeset, :share_token) do
          nil ->
            token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
            Ash.Changeset.force_change_attribute(changeset, :share_token, token)

          _existing ->
            changeset
        end
      end
    end

    update :disable_sharing do
      description "Clear the share token; existing public links stop working"
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.force_change_attribute(changeset, :share_token, nil)
      end
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

      change fn changeset, ctx ->
        Ash.Changeset.after_action(changeset, fn _cs, trip ->
          actor = ctx.actor
          kit_id = Ash.Changeset.get_argument(changeset, :kit_id)

          # Resolve the kit through the actor so an attacker can't pass
          # another user's kit_id and expand it into their own trip.
          kit =
            Packheavy.Inventory.Kit
            |> Ash.get!(kit_id, load: [kit_items: []], actor: actor)

          # The outer Trip action has already authorized that this trip
          # belongs to the actor; the inner join-table writes are
          # implementation details, so bypass authorize here.
          Ash.create!(
            Packheavy.Trips.TripKit,
            %{trip_id: trip.id, kit_id: kit_id},
            upsert?: true,
            upsert_identity: :unique_trip_kit,
            authorize?: false
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
    # Opaque random token for the public read-only share URL. Nullable
    # — a trip is only shareable while the owner has explicitly enabled
    # it. Postgres treats each NULL as distinct, so the unique index
    # below behaves like a partial unique on the non-null values.
    attribute :share_token, :string, allow_nil?: true, public?: false
    timestamps()
  end

  identities do
    identity :share_token, [:share_token]
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
