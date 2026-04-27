defmodule Packheavy.Inventory.Item.Food do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:food]
      default :food
    end

    attribute :calories, :integer, allow_nil?: false, public?: true
    attribute :serving_label, :string, public?: true
  end
end
