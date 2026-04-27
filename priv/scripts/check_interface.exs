require Ash.Query

user =
  Packheavy.Accounts.User
  |> Ash.Query.filter(email == "ben@local")
  |> Ash.read_one!(authorize?: false)

trip =
  Ash.create!(Packheavy.Trips.Trip, %{name: "Interface Test", user_id: user.id},
    authorize?: false
  )

# Try the code interface with explicit bang
trip = Packheavy.Trips.start_packing!(trip, authorize?: false)
IO.inspect(trip.state, label: "after start_packing! interface")

trip = Packheavy.Trips.complete_trip!(trip, authorize?: false)
IO.inspect(trip.state, label: "after complete_trip! interface")
