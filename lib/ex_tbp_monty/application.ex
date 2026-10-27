defmodule ExTbpMonty.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExTbpMontyWeb.Telemetry,
      ExTbpMonty.Repo,
      {DNSCluster, query: Application.get_env(:ex_tbp_monty, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ExTbpMonty.PubSub},
      # Every sensor and learning module registers here, so the step
      # coordinator can address a module by name across restarts.
      {Registry, keys: :unique, name: Monty.Runtime.Registry},
      # One child per running model (module servers + step coordinator).
      {DynamicSupervisor, name: ExTbpMonty.ModelSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      ExTbpMontyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExTbpMonty.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExTbpMontyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
