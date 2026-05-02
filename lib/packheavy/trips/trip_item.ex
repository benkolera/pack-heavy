defmodule Packheavy.Trips.TripItem do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "trip_items"
    repo Packheavy.Repo

    references do
      reference :trip, on_delete: :delete
      reference :item, on_delete: :delete
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(trip.user_id == ^actor(:id))
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:trip_id, :item_id, :qty, :source, :source_kit_id, :carry_mode]
      change Packheavy.Trips.Changes.EnforceItemQtyAvailable
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:qty, :packed, :charged, :tested, :carry_mode]
      change Packheavy.Trips.Changes.EnforceItemQtyAvailable
    end

    update :set_packed do
      argument :packed, :boolean, allow_nil?: false
      change set_attribute(:packed, arg(:packed))
    end

    update :set_charged do
      argument :charged, :boolean, allow_nil?: false
      change set_attribute(:charged, arg(:charged))
    end

    update :set_tested do
      argument :tested, :boolean, allow_nil?: false
      change set_attribute(:tested, arg(:tested))
    end

    update :set_carry_mode do
      argument :carry_mode, :atom, allow_nil?: false, constraints: [one_of: [:worn, :day_pack, :main_pack]]
      change set_attribute(:carry_mode, arg(:carry_mode))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :qty, :integer, allow_nil?: false, default: 1, public?: true,
              constraints: [min: 1]
    attribute :source, :atom do
      allow_nil? false
      default :direct
      public? true
      constraints one_of: [:direct, :kit]
    end
    attribute :source_kit_id, :uuid, public?: true
    attribute :packed, :boolean, allow_nil?: false, default: false, public?: true
    attribute :charged, :boolean, allow_nil?: false, default: false, public?: true

    # User-confirmed it still works (powered on, fits, no leaks, etc.).
    # Independent from `:packed` and `:charged` because functioning ≠
    # charged ≠ in the bag. Surfaced as a tick on the Pack tab.
    attribute :tested, :boolean, allow_nil?: false, default: false, public?: true

    # Where on your person this item rides during the hike. Drives
    # whether it counts toward sidequest carry weight (worn + day_pack
    # only) or full-trip carry weight (everything).
    attribute :carry_mode, :atom do
      allow_nil? false
      default :main_pack
      public? true
      constraints one_of: [:worn, :day_pack, :main_pack]
    end

    timestamps()
  end

  relationships do
    belongs_to :trip, Packheavy.Trips.Trip, allow_nil?: false
    belongs_to :item, Packheavy.Inventory.Item, allow_nil?: false
  end
end
