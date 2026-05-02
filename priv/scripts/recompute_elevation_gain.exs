require Ash.Query

legs =
  Packheavy.Trips.TripLeg
  |> Ash.Query.new()
  |> Ash.read!(authorize?: false)

IO.puts("Recomputing elevation gain for #{length(legs)} legs...")

Enum.each(legs, fn leg ->
  points =
    leg.track
    |> Enum.map(fn p ->
      %{lat: p["lat"] || p[:lat], lon: p["lon"] || p[:lon], ele: p["ele"] || p[:ele]}
    end)

  new_gain = Packheavy.Gpx.elevation_gain_m(points)
  old_gain = leg.elevation_gain_m

  leg
  |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
  |> Ash.Changeset.force_change_attribute(:elevation_gain_m, new_gain)
  |> Ash.update!(authorize?: false)

  IO.puts(
    "  #{leg.name}: #{Float.round(old_gain, 1)} m → #{Float.round(new_gain, 1)} m"
  )
end)

IO.puts("Done.")
