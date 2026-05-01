defmodule Packheavy.Inventory.Item do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "items"
    repo Packheavy.Repo
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  actions do
    defaults [:read, :destroy, update: [:title, :brand, :weight_g, :qty, :notes, :category_data]]

    create :create do
      primary? true
      accept [:title, :brand, :weight_g, :qty, :notes, :category_data]
      change relate_actor(:user)
    end

    update :decrement_qty do
      description "Decrements the on-hand qty by the given amount (clamped to 0)"
      argument :amount, :integer, allow_nil?: false
      require_atomic? false

      change fn changeset, _ctx ->
        current = changeset.data.qty || 0
        amount = Ash.Changeset.get_argument(changeset, :amount)
        Ash.Changeset.force_change_attribute(changeset, :qty, max(current - amount, 0))
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :brand, :string, public?: true
    attribute :weight_g, :integer, allow_nil?: false, default: 0, public?: true
    attribute :qty, :integer, allow_nil?: false, default: 1, public?: true,
              constraints: [min: 0]
    attribute :notes, :string, public?: true

    attribute :category_data, :union do
      allow_nil? false
      public? true

      constraints types: [
                    electronic: [type: Packheavy.Inventory.Item.Electronic, tag: :type, tag_value: :electronic],
                    camera_lens: [type: Packheavy.Inventory.Item.CameraLens, tag: :type, tag_value: :camera_lens],
                    water_container: [type: Packheavy.Inventory.Item.Water, tag: :type, tag_value: :water_container],
                    food: [type: Packheavy.Inventory.Item.Food, tag: :type, tag_value: :food],
                    pack: [type: Packheavy.Inventory.Item.Pack, tag: :type, tag_value: :pack],
                    power: [type: Packheavy.Inventory.Item.Power, tag: :type, tag_value: :power],
                    battery: [type: Packheavy.Inventory.Item.Battery, tag: :type, tag_value: :battery],
                    cable: [type: Packheavy.Inventory.Item.Cable, tag: :type, tag_value: :cable],
                    shelter: [type: Packheavy.Inventory.Item.Shelter, tag: :type, tag_value: :shelter],
                    sleep: [type: Packheavy.Inventory.Item.Sleep, tag: :type, tag_value: :sleep],
                    cooking: [type: Packheavy.Inventory.Item.Cooking, tag: :type, tag_value: :cooking],
                    first_aid: [type: Packheavy.Inventory.Item.FirstAid, tag: :type, tag_value: :first_aid],
                    hygiene: [type: Packheavy.Inventory.Item.Hygiene, tag: :type, tag_value: :hygiene],
                    clothing: [type: Packheavy.Inventory.Item.Clothing, tag: :type, tag_value: :clothing],
                    containers: [type: Packheavy.Inventory.Item.Containers, tag: :type, tag_value: :containers],
                    tools: [type: Packheavy.Inventory.Item.Tools, tag: :type, tag_value: :tools],
                    other: [type: Packheavy.Inventory.Item.Other, tag: :type, tag_value: :other]
                  ]
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Packheavy.Accounts.User, allow_nil?: false
  end

  calculations do
    calculate :category, :atom, expr(fragment("(?->>'type')::text", category_data))
  end
end
