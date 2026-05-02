defmodule Packheavy.Trips.TripHiker do
  @moduledoc """
  A hiker on a trip — typically the trip owner is the leader, with
  optional companions added later. Personal contact info lives here
  (phone, satellite SMS, location tracker URL+password) so the trip
  detail page can render the full hike-handout group block.

  Created at trip-create time from the user's profile defaults; the
  in-trip copy is independently editable so a profile change doesn't
  retroactively rewrite past trips' hikers.
  """

  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "trip_hikers"
    repo Packheavy.Repo

    references do
      reference :trip, on_delete: :delete
      reference :user, on_delete: :nilify
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
    :user_id,
    :name,
    :role,
    :phone,
    :satellite_sms,
    :location_tracker_url,
    :location_tracker_password,
    :weight_kg,
    :notes,
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
      accept @editable_attrs -- [:trip_id, :user_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :member
      constraints one_of: [:leader, :member]
    end

    attribute :phone, :string, public?: true
    attribute :satellite_sms, :string, public?: true
    attribute :location_tracker_url, :string, public?: true

    attribute :location_tracker_password, :string do
      public? true
      sensitive? true
    end

    attribute :weight_kg, :decimal, public?: true
    attribute :notes, :string, public?: true
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    timestamps()
  end

  relationships do
    belongs_to :trip, Packheavy.Trips.Trip, allow_nil?: false
    belongs_to :user, Packheavy.Accounts.User, allow_nil?: true
  end
end
