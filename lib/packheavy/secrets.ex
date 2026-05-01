defmodule Packheavy.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Packheavy.Accounts.User,
        _opts,
        _context
      ),
      do: Application.fetch_env(:packheavy, :token_signing_secret)

  def secret_for(
        [:authentication, :strategies, :auth0, key],
        Packheavy.Accounts.User,
        _opts,
        _context
      )
      when key in [:client_id, :client_secret, :base_url, :redirect_uri] do
    Application.fetch_env(:packheavy, :"auth0_#{key}")
  end
end
