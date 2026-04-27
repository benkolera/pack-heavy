defmodule Packheavy.Trips.TripKit do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "trip_kits"
    repo Packheavy.Repo

    references do
      reference :trip, on_delete: :delete
      reference :kit, on_delete: :delete
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
