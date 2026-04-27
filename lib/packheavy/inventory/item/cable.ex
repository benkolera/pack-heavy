defmodule Packheavy.Inventory.Item.Cable do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:cable]
      default :cable
    end

    attribute :cable_type_id, :uuid, allow_nil?: false, public?: true
  end
end
