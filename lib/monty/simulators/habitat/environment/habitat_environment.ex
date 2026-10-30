defmodule Monty.Simulators.Habitat.Environment.HabitatEnvironment do
  @moduledoc """
  Monty's world: `tbp/monty/simulators/habitat/environment.py::HabitatEnvironment`.

  The class is not reimplemented here, and cannot be: a scene is `habitat_sim`,
  physics in Python and C++, and the experiment's own positioning procedure
  decides where the agent starts. What this module is, is that world on this
  side of a process boundary. `scripts/monty_simulator_peer.py` runs Monty's
  `HabitatEnvironment` and the experiment's environment interface inside the
  environment Monty lives in; `Monty.Simulators.Port.Environment` owns that
  process and speaks the port's protocol to it.

  So the struct is a handle and a step is a round trip: the world a step leaves
  behind is the same struct, holding the process. That is why `new/1` does not
  start anything — a run builds a world it may never step, and the peer costs a
  conda environment and a scene load to start.

  ## Choosing it

  `Monty.Studio.Setup` builds this world for a run when the application says
  so:

      config :ex_tbp_monty, world_simulator: :habitat

  and `:monty_peer` says what Monty's process needs:

      config :ex_tbp_monty,
        monty_peer: [
          python: "/path/to/envs/tbp.monty/bin/python",
          overrides: ["constants.pretrained_dir=/path/to/models"]
        ]

  Monty's own defaults are what a run uses when nothing is configured: `python3`
  from the PATH, this project's peer script, no overrides, and the Monty source
  the configs were read from on `PYTHONPATH`.
  """

  @behaviour Monty.Simulators.Environment

  alias Monty.Simulators.Port.Environment

  # A Habitat scene is built on the first step and the first frame is compiled
  # with it, which is slower than any later step. A minute is not generous for
  # that, and a step after it that hangs should end the run rather than stall.
  @default_timeout 120_000

  defstruct experiment: nil,
            sensors: [],
            command: nil,
            env: [],
            timeout: @default_timeout,
            server: nil

  @typedoc """
  A world named by an experiment, not yet started.
  """
  @type t :: %__MODULE__{
          experiment: String.t() | nil,
          sensors: [Monty.Simulators.Environment.sensor_id()],
          command: [String.t()] | nil,
          env: [{String.t(), String.t()}],
          timeout: timeout(),
          server: GenServer.server() | nil
        }

  @doc """
  The world `:experiment` names.

  Options, each over the top of `:monty_peer`:

    * `:experiment` — Monty's config name, which is what picks the scene;
    * `:sensors` — the sensors the experiment's agent has;
    * `:python` — the interpreter Monty lives in;
    * `:peer` — the script that runs Monty's world;
    * `:overrides` — Hydra overrides, as Monty's own command line takes them;
    * `:env` — the environment the peer starts in (default: Monty's source on
      `PYTHONPATH`);
    * `:timeout` — how long one step may take.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(options) do
    options = Keyword.merge(peer_options(), options)
    experiment = Keyword.fetch!(options, :experiment)

    %__MODULE__{
      experiment: experiment,
      sensors: Keyword.get(options, :sensors, []),
      command: command(options, experiment),
      env: Keyword.get_lazy(options, :env, &monty_source/0),
      timeout: Keyword.get(options, :timeout, @default_timeout)
    }
  end

  @doc """
  What this machine tells Monty's process: `:monty_peer` in the application
  configuration, empty when nothing is configured.
  """
  @spec peer_options() :: keyword()
  def peer_options, do: Application.get_env(:ex_tbp_monty, :monty_peer, [])

  @doc """
  The world after `actions`, and the process that is now serving it.

  A world that cannot step is not a step that produced nothing: the run ends
  here rather than stepping on a scene it is out of step with.
  """
  @impl true
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: {map(), map(), t()}
  def step(%__MODULE__{} = world, actions) do
    server = server(world)

    case Environment.step(server, actions) do
      {:ok, observations, proprioceptive_state} ->
        {observations, proprioceptive_state, %{world | server: server}}

      {:error, reason} ->
        raise "the world behind #{world.experiment} could not step: #{inspect(reason)}"
    end
  end

  @doc """
  The next episode: the experiment's own `pre_episode`, run in the peer.

  This answers the world before its first observation — Monty's `Interface`
  takes the no-action step that follows, and that is what shows it.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = world) do
    server = server(world)

    case Environment.reset(server) do
      :ok ->
        %{world | server: server}

      {:error, reason} ->
        raise "the world behind #{world.experiment} could not reset: #{inspect(reason)}"
    end
  end

  @doc """
  Closes the peer. A world that never stepped never started one.
  """
  @impl true
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{server: nil}), do: :ok

  def stop(%__MODULE__{server: server}) do
    Environment.stop(server)
  catch
    # A peer that has already exited took its process with it.
    :exit, _reason -> :ok
  end

  # The peer is started on the first step, by whichever process takes it, so it
  # lives exactly as long as the run does.
  defp server(%__MODULE__{server: nil} = world) do
    options = [
      command: world.command,
      sensor_ids: world.sensors,
      timeout: world.timeout,
      env: world.env
    ]

    case Environment.start_link(options) do
      {:ok, server} ->
        server

      {:error, reason} ->
        raise "the world behind #{world.experiment} did not start: #{inspect(reason)}"
    end
  end

  defp server(%__MODULE__{server: server}), do: server

  defp command(options, experiment) do
    overrides = Keyword.get(options, :overrides, [])

    [python(options), peer_script(options), "--experiment", experiment] ++ overrides
  end

  defp python(options) do
    Keyword.get(options, :python) || System.find_executable("python3") ||
      raise ArgumentError,
            "no python3 on the PATH: configure :monty_peer with python: the interpreter Monty lives in"
  end

  defp peer_script(options) do
    Keyword.get_lazy(options, :peer, fn ->
      Path.expand("../../../../../scripts/monty_simulator_peer.py", __DIR__)
    end)
  end

  # The peer imports Monty from its source tree, which is the tree the configs
  # and the pretrained memory were read from.
  defp monty_source, do: [{"PYTHONPATH", Path.join(Monty.Config.Source.root(), "src")}]
end
