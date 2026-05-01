defmodule Packheavy.Inventory.KitItem do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "kit_items"
    repo Packheavy.Repo

    references do
      reference :kit, on_delete: :delete
      reference :item, on_delete: :delete
    end
  end

  # No direct user_id — scope through the parent kit's owner. Forging
  # a kit_id from another user is bounded by the fact that Kit's own
  # policies prevent enumerating other users' kits, so the kit_id has
  # to be a UUID you can't otherwise read.
  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(kit.user_id == ^actor(:id))
    end
  end

  actions do
    defaults [:read, :destroy,
              create: [:kit_id, :item_id, :qty],
              update: [:qty]]
  end

  attributes do
    uuid_primary_key :id
    attribute :qty, :integer, allow_nil?: false, default: 1, public?: true,
              constraints: [min: 1]
    timestamps()
  end

  relationships do
    belongs_to :kit, Packheavy.Inventory.Kit, allow_nil?: false
    belongs_to :item, Packheavy.Inventory.Item, allow_nil?: false
  end

  identities do
    identity :unique_kit_item, [:kit_id, :item_id]
  end
end
