defmodule ExTbpMonty.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

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
      # One child per prerequisite download, restarted never: a download either
      # finishes or is started again deliberately.
      {DynamicSupervisor, name: ExTbpMonty.PrerequisitesSupervisor, strategy: :one_for_one},
      # Experiment runs are queued jobs, so closing a page does not close a run.
      {Oban, Application.fetch_env!(:ex_tbp_monty, Oban)},
      # Start to serve requests, typically the last entry
      ExTbpMontyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExTbpMonty.Supervisor]

    # Said once, at boot: which build this is, so a log from a container that
    # started for someone else's deploy can still be identified.
    Logger.info("build: #{ExTbpMonty.BuildInfo.description()}")

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # One log line per request, none for the health probe: Phoenix's own
        # request logger is off in `config :phoenix, :logger`.
        ExTbpMontyWeb.Telemetry.RequestLog.attach()
        # A run's record is closed by the job that executes it, and a node that
        # restarts takes those jobs with it: whatever was `running` a moment ago
        # is not running now.
        Monty.Studio.Jobs.Reaper.sweep()
        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExTbpMontyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
