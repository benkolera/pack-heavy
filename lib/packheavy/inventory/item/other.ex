defmodule Packheavy.Inventory.Item.Other do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:other]
      default :other
    end
  end
end
