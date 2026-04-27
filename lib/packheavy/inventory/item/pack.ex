defmodule Packheavy.Inventory.Item.Pack do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:pack]
      default :pack
    end

    attribute :volume_l, :float, allow_nil?: false, public?: true
  end
end
