defmodule Packheavy.Accounts do
  use Ash.Domain,
    otp_app: :packheavy

  resources do
    resource Packheavy.Accounts.Token
    resource Packheavy.Accounts.User
  end
end
