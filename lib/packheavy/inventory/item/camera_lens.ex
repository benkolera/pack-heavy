defmodule Packheavy.Inventory.Item.CameraLens do
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept :*
      change Packheavy.Inventory.Item.CameraLens.NormalizePrime
    end

    update :update do
      primary? true
      accept :*
      change Packheavy.Inventory.Item.CameraLens.NormalizePrime
    end
  end

  attributes do
    attribute :type, :atom do
      allow_nil? false
      writable? true
      public? true
      constraints one_of: [:camera_lens]
      default :camera_lens
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :prime
      constraints one_of: [:prime, :zoom]
    end

    attribute :focal_length_min, :integer, allow_nil?: false, public?: true,
              constraints: [min: 1]
    attribute :focal_length_max, :integer, allow_nil?: false, public?: true,
              constraints: [min: 1]
    attribute :aperture_wide, :float, public?: true, constraints: [min: 0.5]
    attribute :aperture_tele, :float, public?: true, constraints: [min: 0.5]
  end
end

defmodule Packheavy.Inventory.Item.CameraLens.NormalizePrime do
  @moduledoc """
  For prime lenses, mirror the single-value fields into the *_min/*_max
  pair so storage stays uniform across primes and zooms.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn cs ->
      case Ash.Changeset.get_attribute(cs, :kind) do
        :prime ->
          fmin = Ash.Changeset.get_attribute(cs, :focal_length_min)
          ap_wide = Ash.Changeset.get_attribute(cs, :aperture_wide)

          cs
          |> Ash.Changeset.force_change_attribute(:focal_length_max, fmin)
          |> Ash.Changeset.force_change_attribute(:aperture_tele, ap_wide)

        _ ->
          cs
      end
    end)
  end
end
