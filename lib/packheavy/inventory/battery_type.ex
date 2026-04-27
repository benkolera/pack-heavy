defmodule Packheavy.Inventory.BatteryType do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Inventory,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_types"
    repo Packheavy.Repo
  end

  actions do
    defaults [:read, :destroy, update: [:name, :rechargeable]]

    create :create do
      primary? true
      accept [:name, :rechargeable]
      change relate_actor(:user)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :rechargeable, :boolean, allow_nil?: false, default: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :user, Packheavy.Accounts.User, allow_nil?: false
  end

  identities do
    identity :name_per_user, [:name, :user_id]
  end
end
