# Seeds default cable & battery types for any user that doesn't have them yet.
# Idempotent: safe to re-run after each `mix ash.setup` / new user registration.
#
# Run with: mix run priv/repo/seeds.exs

cable_names = ["USB-C", "Micro-USB", "Lightning", "USB-A", "Proprietary"]
battery_names = ["AA", "AAA", "CR123A", "CR2032", "CR2016", "18650"]

users = Ash.read!(Packheavy.Accounts.User, authorize?: false)

if users == [] do
  IO.puts("No users yet — register at /register first, then re-run seeds.")
end

Enum.each(users, fn user ->
  IO.puts("Seeding types for #{user.email}...")

  Enum.each(cable_names, fn name ->
    Ash.create!(
      Packheavy.Inventory.CableType,
      %{name: name, user_id: user.id},
      authorize?: false,
      upsert?: true,
      upsert_identity: :name_per_user
    )
  end)

  Enum.each(battery_names, fn name ->
    Ash.create!(
      Packheavy.Inventory.BatteryType,
      %{name: name, user_id: user.id},
      authorize?: false,
      upsert?: true,
      upsert_identity: :name_per_user
    )
  end)
end)

IO.puts("Done.")
