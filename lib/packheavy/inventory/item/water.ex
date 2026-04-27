defmodule Packheavy.Inventory.Item.Water do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:water_container]
      default :water_container
    end

    attribute :capacity_ml, :integer, allow_nil?: false, public?: true
  end
end
