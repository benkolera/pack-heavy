defmodule Packheavy.Inventory do
  use Ash.Domain, otp_app: :packheavy

  resources do
    resource Packheavy.Inventory.CableType do
      define :create_cable_type, action: :create
      define :list_cable_types, action: :read
      define :get_cable_type, action: :read, get_by: :id
    end

    resource Packheavy.Inventory.BatteryType do
      define :create_battery_type, action: :create
      define :list_battery_types, action: :read
      define :get_battery_type, action: :read, get_by: :id
    end

    resource Packheavy.Inventory.Item do
      define :create_item, action: :create
      define :update_item, action: :update
      define :list_items, action: :read
      define :get_item, action: :read, get_by: :id
      define :destroy_item, action: :destroy
    end

    resource Packheavy.Inventory.Kit do
      define :create_kit, action: :create
      define :update_kit, action: :update
      define :list_kits, action: :read
      define :get_kit, action: :read, get_by: :id
      define :destroy_kit, action: :destroy
    end

    resource Packheavy.Inventory.KitItem do
      define :add_kit_item, action: :create
      define :update_kit_item, action: :update
      define :remove_kit_item, action: :destroy
    end
  end
end
