defmodule Packheavy.Trips.TripLeg do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Trips,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "trip_legs"
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

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :trip_id,
        :position,
        :day,
        :name,
        :gpx_filename,
        :distance_m,
        :elevation_gain_m,
        :point_count,
        :track,
        :pace_kmh,
        :sidequest,
        :notes
      ]
    end

    update :update do
      primary? true
      accept [:name, :position, :day, :pace_kmh, :sidequest, :notes]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :position, :integer, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :gpx_filename, :string, public?: true
    attribute :distance_m, :float, allow_nil?: false, public?: true
    attribute :elevation_gain_m, :float, allow_nil?: false, public?: true
    attribute :point_count, :integer, allow_nil?: false, public?: true

    # Average flat-ground walking pace in km/h. Naismith's rule baseline
    # is 4.0 — bump up for fit groups on easy track, down for rough
    # scrambles. Per-leg so multi-day trips can vary day to day.
    attribute :pace_kmh, :float, allow_nil?: false, default: 4.0, public?: true

    # 1-indexed day-of-trip. Multiple legs can share a day (e.g. a base
    # camp followed by a sidequest peak). Day 1 is the day you set off.
    attribute :day, :integer, allow_nil?: false, default: 1, public?: true

    # Day-pack-only segment (e.g. summit out-and-back from a base
    # camp): only worn + day-pack items count toward the carry weight,
    # so the calorie estimate uses a lighter load on this leg.
    attribute :sidequest, :boolean, allow_nil?: false, default: false, public?: true

    # Optional Markdown notes for this leg — terrain warnings, water
    # sources, river crossings, photo spots, etc. Rendered everywhere
    # the leg appears (planner, public share, handout).
    attribute :notes, :string, public?: true

    # Per-trackpoint canonical track [%{lat, lon, ele, d}]. Stored
    # parsed (not raw GPX) so the trip page renders without re-parsing.
    # Re-upload is required if the parser changes — fine for prototype.
    attribute :track, {:array, :map}, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :trip, Packheavy.Trips.Trip, allow_nil?: false
  end

  identities do
    identity :unique_position_per_trip, [:trip_id, :position]
  end
end
