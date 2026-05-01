defmodule Packheavy.Trips.TripKit do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "trip_kits"
    repo Packheavy.Repo

    references do
      reference :trip, on_delete: :delete
      reference :kit, on_delete: :delete
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
    defaults [:read, :destroy, create: [:trip_id, :kit_id]]
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :trip, Packheavy.Trips.Trip, allow_nil?: false
    belongs_to :kit, Packheavy.Inventory.Kit, allow_nil?: false
  end

  identities do
    identity :unique_trip_kit, [:trip_id, :kit_id]
  end
end
