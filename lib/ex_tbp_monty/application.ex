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
      # The repo this instance was started with: Postgres when `DATABASE_URL`
      # names one, SQLite in a file otherwise.
      ExTbpMonty.Database.repo_module(),
      {DNSCluster, query: Application.get_env(:ex_tbp_monty, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ExTbpMonty.PubSub},
      # Every sensor and learning module registers here, so the step
      # coordinator can address a module by name across restarts.
      {Registry, keys: :unique, name: Monty.Runtime.Registry},
      # One child per running model (module servers + step coordinator).
      {DynamicSupervisor, name: ExTbpMonty.ModelSupervisor, strategy: :one_for_one},
      # The steps of runs that are still stepping, kept in memory: a run's
      # transcript reaches its page from here, and the database is written when
      # the run settles rather than once per step.
      Monty.Studio.RunStream,
      # The one process that writes a run's steps: a boundary hands them over and
      # steps on, so the experiment never waits for Postgres.
      Monty.Studio.RunWriter,
      # One child per prerequisite download, restarted never: a download either
      # finishes or is started again deliberately.
      {DynamicSupervisor, name: ExTbpMonty.PrerequisitesSupervisor, strategy: :one_for_one},
      # The world: MuJoCo, through this application's own Python
      # (`priv/monty_py`), hosted in the interpreter this application carries.
      # One process, because a step is a model, an agent and a camera read in
      # sequence, and two runs must not interleave inside one.
      Monty.Simulators.Mujoco.Host,
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
        warm_catalogue()
        prefetch()
        {:ok, pid}

      error ->
        error
    end
  end

  # The experiments list reads 210 YAML files the first time it is asked for
  # (`Monty.Studio.Catalog` caches them after that). Paying it while the first
  # page loads makes that page the slowest a new deployment has, so it is paid
  # here, in a process of its own, before anybody asks.
  defp warm_catalogue do
    if Application.get_env(:ex_tbp_monty, :precompute, true) do
      Task.start(fn -> Monty.Studio.Catalog.experiments() end)
    end

    :ok
  end

  # A first start has no data and a run cannot use what is not there, so the
  # bundles are fetched here — in the background, never in front of the server:
  # the page answers while a gigabyte arrives, and `/prerequisites` shows every
  # download as it happens.
  #
  # Every prerequisite with work left is started, not only the ones that are
  # absent: an archive that is here with its memory unread is as unusable as one
  # that never arrived, and which of the two it is cannot be told by looking for
  # a file. `Prerequisites.unfinished/0` is the one that answers that, from the
  # manifest and from the machines that did the earlier work.
  #
  # Started one at a time, on purpose: several gigabyte downloads at once share
  # one connection, and each saga outlives this process — a person can watch
  # them, cancel them, and close the tab. `PREFETCH=0` turns it off.
  defp prefetch do
    if Application.get_env(:ex_tbp_monty, :prefetch, false) do
      Task.start(fn ->
        for prerequisite <- Monty.Prerequisites.unfinished(),
            is_nil(Monty.Prerequisites.Saga.lookup(prerequisite.id)) do
          Monty.Prerequisites.fetch(prerequisite)
        end
      end)
    end

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExTbpMontyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
