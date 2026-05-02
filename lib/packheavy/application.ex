defmodule Packheavy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Packheavy.Weather.init_cache()

    children = [
      PackheavyWeb.Telemetry,
      Packheavy.Repo,
      {DNSCluster, query: Application.get_env(:packheavy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Packheavy.PubSub},
      # Start a worker by calling: Packheavy.Worker.start_link(arg)
      # {Packheavy.Worker, arg},
      # Start to serve requests, typically the last entry
      PackheavyWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :packheavy]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Packheavy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PackheavyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
