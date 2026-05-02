defmodule Packheavy.Trips.TripContact do
  @moduledoc """
  Off-trip contacts attached to a trip — split into two kinds:

    * `:emergency_primary` — single point of escalation if the hiking
      group misses its check-in. Holds an `escalation_criteria` text
      field describing when they should call emergency services.

    * `:daily_checkin` — friends/family who get daily SMS updates
      from the hiker(s) while in the field.

  Stored as one resource with a kind discriminator rather than two
  separate resources — the shape is identical and the index UI can
  group by `kind`.
  """

  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "trip_contacts"
    repo Packheavy.Repo

    references do
      reference :trip, on_delete: :delete
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(trip.user_id == ^actor(:id))
    end
  end

  @editable_attrs [
    :trip_id,
    :name,
    :relationship,
    :phone,
    :kind,
    :escalation_criteria,
    :position
  ]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept @editable_attrs
    end

    update :update do
      primary? true
      accept @editable_attrs -- [:trip_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :relationship, :string, public?: true
    attribute :phone, :string, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:emergency_primary, :daily_checkin]
    end

    # Only meaningful when kind == :emergency_primary; freeform text
    # describing the trigger (e.g. "if I don't check in by Mon 7pm").
    attribute :escalation_criteria, :string, public?: true
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    timestamps()
  end

  relationships do
    belongs_to :trip, Packheavy.Trips.Trip, allow_nil?: false
  end
end
