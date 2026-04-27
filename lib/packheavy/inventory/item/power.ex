defmodule Packheavy.Inventory.Item.Power do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:power]
      default :power
    end

    attribute :capacity_mah, :integer, allow_nil?: false, public?: true
    attribute :usb_ports, :integer, allow_nil?: false, default: 1, public?: true
  end
end
