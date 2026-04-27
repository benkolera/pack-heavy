defmodule Packheavy.Inventory.Item.Electronic do
  use Ash.Resource, data_layer: :embedded

  @power_sources [:built_in, :batteries]
  def power_sources, do: @power_sources

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:electronic]
      default :electronic
    end

    attribute :power_source, :atom do
      allow_nil? false
      public? true
      constraints one_of: @power_sources
      default :built_in
    end

    # When power_source == :built_in
    attribute :charger_cable_type_id, :uuid, public?: true

    # When power_source == :batteries
    attribute :battery_type_id, :uuid, public?: true
    attribute :battery_count, :integer, default: 0, public?: true
  end
end
