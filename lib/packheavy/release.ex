defmodule Packheavy.Release do
  @moduledoc """
  Release-time tasks. Invoked from `rel/env.sh.eex` so a fresh container
  applies pending migrations before the Phoenix endpoint starts. Mix is not
  available inside an OTP release, so we drive Ecto.Migrator directly.
  """

  @app :packheavy

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Packheavy.Repo, fn _repo ->
        Application.ensure_all_started(:packheavy)
        recompute_trip_leg_elevation_gain()
      end)
  end

  # Idempotent fix-up: recompute each TripLeg's elevation_gain_m from the
  # stored canonical track and write it back only when the value changes.
  # Lets us correct previously cached gains after the parser bug fix
  # without manual intervention. Future boots find no drift and no-op.
  defp recompute_trip_leg_elevation_gain do
    require Ash.Query

    legs = Ash.read!(Packheavy.Trips.TripLeg, authorize?: false)

    for leg <- legs do
      points =
        Enum.map(leg.track, fn p ->
          %{lat: p["lat"] || p[:lat], lon: p["lon"] || p[:lon], ele: p["ele"] || p[:ele]}
        end)

      new_gain = Packheavy.Gpx.elevation_gain_m(points)

      if abs(new_gain - leg.elevation_gain_m) > 0.5 do
        leg
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:elevation_gain_m, new_gain)
        |> Ash.update!(authorize?: false)
      end
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
