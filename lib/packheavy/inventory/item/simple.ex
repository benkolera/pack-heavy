defmodule Packheavy.Inventory.Item.Simple do
  @moduledoc """
  Macro for defining "plain" item category embedded resources — categories
  whose only data is the discriminator. Used for shelter/sleep/cooking/etc.
  """

  defmacro __using__(type: type) do
    quote do
      use Ash.Resource, data_layer: :embedded

      actions do
        defaults [:read, :destroy, create: :*, update: :*]
      end

      attributes do
        attribute :type, :atom do
          allow_nil? false
          writable? true
          public? true
          constraints one_of: [unquote(type)]
          default unquote(type)
        end
      end
    end
  end
end

defmodule Packheavy.Inventory.Item.Shelter do
  use Packheavy.Inventory.Item.Simple, type: :shelter
end

defmodule Packheavy.Inventory.Item.Sleep do
  use Packheavy.Inventory.Item.Simple, type: :sleep
end

defmodule Packheavy.Inventory.Item.Cooking do
  use Packheavy.Inventory.Item.Simple, type: :cooking
end

defmodule Packheavy.Inventory.Item.FirstAid do
  use Packheavy.Inventory.Item.Simple, type: :first_aid
end

defmodule Packheavy.Inventory.Item.Hygiene do
  use Packheavy.Inventory.Item.Simple, type: :hygiene
end

defmodule Packheavy.Inventory.Item.Clothing do
  use Packheavy.Inventory.Item.Simple, type: :clothing
end

defmodule Packheavy.Inventory.Item.Containers do
  use Packheavy.Inventory.Item.Simple, type: :containers
end

defmodule Packheavy.Inventory.Item.Tools do
  use Packheavy.Inventory.Item.Simple, type: :tools
end
