defmodule Packheavy.Inventory.Kit do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Inventory,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "kits"
    repo Packheavy.Repo
  end

  actions do
    defaults [:read, :destroy, update: [:name, :description]]

    create :create do
      primary? true
      accept [:name, :description]
      change relate_actor(:user)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    timestamps()
  end

  relationships do
    belongs_to :user, Packheavy.Accounts.User, allow_nil?: false
    has_many :kit_items, Packheavy.Inventory.KitItem
  end

  aggregates do
    count :item_count, :kit_items
    sum :total_qty, :kit_items, field: :qty
  end
end
