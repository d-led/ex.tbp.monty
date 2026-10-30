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
  from the PATH, this project's peer script, no overrides, and the Monty checkout
  the configs were read from, named to the peer with `--monty-root` — the peer
  has to be told which Monty to import, or a relative path quietly picks another.
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
            timeout: @default_timeout,
            server: nil,
            primary_target: nil

  @typedoc """
  A world named by an experiment, not yet started, and what its last episode was
  about once one has been started.
  """
  @type t :: %__MODULE__{
          experiment: String.t() | nil,
          sensors: [Monty.Simulators.Environment.sensor_id()],
          command: [String.t()] | nil,
          timeout: timeout(),
          server: GenServer.server() | nil,
          primary_target: map() | nil
        }

  @doc """
  The world `:experiment` names.

  Options, each over the top of `:monty_peer`:

    * `:experiment` — Monty's config name, which is what picks the scene;
    * `:sensors` — the sensors the experiment's agent has;
    * `:python` — the interpreter Monty lives in;
    * `:peer` — the script that runs Monty's world;
    * `:overrides` — Hydra overrides, as Monty's own command line takes them;
    * `:monty_root` — the checkout the peer runs, given to it by name (default:
      the source the configs were read from);
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
      timeout: Keyword.get(options, :timeout, @default_timeout)
    }
  end

  @doc """
  What this machine tells Monty's process: `:monty_peer` in the application
  configuration, with `$MONTY_PYTHON` for the interpreter when the configuration
  does not name one.
  """
  @spec peer_options() :: keyword()
  def peer_options do
    :ex_tbp_monty
    |> Application.get_env(:monty_peer, [])
    |> Keyword.put_new_lazy(:python, fn -> System.get_env("MONTY_PYTHON") end)
  end

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
      {:ok, episode} ->
        %{world | server: server, primary_target: Map.get(episode, "primary_target")}

      {:error, reason} ->
        raise "the world behind #{world.experiment} could not reset: #{inspect(reason)}"
    end
  end

  @doc """
  The object this episode is about, as the peer's `pre_episode` chose it.

  `nil` until an episode has been started: the peer chooses the object while it
  positions the agent, and before that there is nothing to report. Monty's
  interface is the one that knows; this is the answer to the question it would
  give.
  """
  @impl true
  @spec primary_target(t()) :: map() | nil
  def primary_target(%__MODULE__{primary_target: primary_target}), do: primary_target

  @doc """
  True: this world positions an episode itself.

  `reset/1` runs Monty's `pre_episode` in the peer — the experiment's own
  positioning procedures, drawing from the episode's random stream in Monty's
  environment — so a run must not position the agent a second time. What the
  model sees first is then what Monty's model would see first.
  """
  @impl true
  @spec positions_itself?() :: true
  def positions_itself?, do: true

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
      timeout: world.timeout
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

    [python(options), peer_script(options), "--experiment", experiment] ++
      monty_root(options) ++ overrides
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

  # The peer imports Monty, so it has to be told *which* Monty: a relative or
  # inherited import path quietly picks a different checkout.
  defp monty_root(options) do
    case Keyword.get_lazy(options, :monty_root, &Monty.Config.Source.root/0) do
      nil -> []
      root -> ["--monty-root", root]
    end
  end
end
