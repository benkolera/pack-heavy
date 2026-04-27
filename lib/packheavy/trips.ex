defmodule Packheavy.Trips do
  use Ash.Domain, otp_app: :packheavy

  resources do
    resource Packheavy.Trips.Trip do
      define :create_trip, action: :create
      define :update_trip, action: :update
      define :list_trips, action: :read
      define :get_trip, action: :read, get_by: :id
      define :destroy_trip, action: :destroy
      define :start_packing, action: :start_packing
      define :complete_trip, action: :complete
      define :add_kit, action: :add_kit, args: [:kit_id]
    end

    resource Packheavy.Trips.TripItem do
      define :add_trip_item, action: :create
      define :update_trip_item, action: :update
      define :remove_trip_item, action: :destroy
      define :set_packed, action: :set_packed, args: [:packed]
      define :set_charged, action: :set_charged, args: [:charged]
    end

    resource Packheavy.Trips.TripKit
  end
end
