require Ash.Query

email = System.get_env("USER_EMAIL") || "ben@local"
password = System.get_env("USER_PASSWORD") || "password123"

case Packheavy.Accounts.User
     |> Ash.Query.filter(email == ^email)
     |> Ash.read_one(authorize?: false) do
  {:ok, nil} ->
    user =
      Packheavy.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: password, password_confirmation: password},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    IO.puts("Created user: #{user.email}")

  {:ok, _existing} ->
    IO.puts("User already exists: #{email}")
end

# Always seed default cable + battery types for that user
Code.eval_file("priv/repo/seeds.exs")
