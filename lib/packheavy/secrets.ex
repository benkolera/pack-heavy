defmodule Packheavy.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Packheavy.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:packheavy, :token_signing_secret)
  end
end
