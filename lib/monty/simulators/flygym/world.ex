defmodule Monty.Simulators.Flygym.World do
  @moduledoc """
  A fly's body in MuJoCo, on the other side of a port.

  The body is FlyGym's NeuroMechFly, composed with drivable legs, stepped by
  `priv/monty_py/fly_peer.py` — a peer script, because
  `Monty.Simulators.Port.Environment` already starts a simulator as a command and
  speaks `Monty.Simulators.Port.Protocol` to it. So nothing here is a new
  contract: this module is the world a run threads, and the peer is the body.

  ## The interpreter is a machine's, not ours

  FlyGym installs MuJoCo 3.16, while the interpreter this application carries is
  pinned to 4.0.1 (`config/pythonx.exs` says why), and one interpreter cannot
  hold both. The body therefore runs in an interpreter a machine supplies, named
  by `FLYGYM_PYTHON`; `examples/flyverse_plugin/scripts/fly_body.py` says how to
  make one and what it measured. `available?/0` answers before a run is opened
  and `unavailable_reason/0` says what to do, so a node without one refuses the
  experiment instead of failing inside it.

  ## What the body answers

  A pose in metres and a `wxyz` rotation — where the fly got to — and per eye the
  compound eye's own percept: 721 ommatidia, each reading one of two
  photoreceptor types, yellow and pale. That is not a camera's RGBA patch, so a
  sensor module written for Monty's `CameraSM` cannot read it; a body this
  different needs a percept of its own, which is the next piece and is written
  down as one.

  ## What the actions mean

  The peer takes Monty's own action maps, unchanged — `OrientHorizontal` is a
  turn and a stride, which is what the body takes once the peer has done the
  arithmetic. A turn is closed on the body's heading inside the peer, because the
  gait's two directions are not symmetric (measured: 119°/s one way, 352°/s the
  other), so a gain would be a fiction.
  """

  @behaviour Monty.Simulators.Environment

  alias Monty.Simulators.Port.Environment

  @python "FLYGYM_PYTHON"

  @script "fly_peer.py"

  # A fly's two compound eyes, in the order the body reports them.
  @sensors ["left", "right"]

  defstruct port: nil,
            python: nil,
            name: nil,
            started?: false,
            sensors: @sensors

  @typedoc """
  One run's body: the process that owns it, the interpreter that has the body in
  it, and the sensors it was asked for.

  There is no scene and no target: an episode of a fly is the fly, and what the
  model does in it is the experiment's business rather than the world's.
  """
  @type t :: %__MODULE__{
          port: GenServer.server() | nil,
          python: String.t() | nil,
          name: GenServer.name() | nil,
          started?: boolean(),
          sensors: [String.t()]
        }

  @doc """
  Whether this machine has an interpreter with the fly body in it.
  """
  @spec available?() :: boolean()
  def available?, do: interpreter() != nil

  @doc """
  The interpreter with the body in it, or `nil` when this machine has none.

  Two places, in this order:

    1. `FLYGYM_PYTHON`, which a machine may point at a virtualenv of its own;
    2. the application's data directory, `fly/bin/python` — where the page's own
       recipe puts one. That path is the machine's rather than the repository's,
       which is why it is the second: a checkout carries no absolute path, and a
       person who has the body gets it without setting anything.
  """
  @spec interpreter() :: String.t() | nil
  def interpreter do
    System.get_env(@python) || installed_interpreter()
  end

  @doc """
  Where this application would find a body, installed by the recipe it prints.
  """
  @spec installed_path() :: String.t()
  def installed_path do
    venv = Path.join(Monty.Paths.data(), "fly")

    if match?({:win32, _}, :os.type()),
      do: Path.join([venv, "Scripts", "python.exe"]),
      else: Path.join([venv, "bin", "python"])
  end

  @doc """
  What to do about it, in words — empty when there is nothing to do.
  """
  @spec unavailable_reason() :: String.t()
  def unavailable_reason do
    if available?() do
      ""
    else
      "no interpreter with the fly body: neither #{@python} nor #{installed_path()} exists. " <>
        "Make one with the commands on this page, or point #{@python} at a virtualenv that has " <>
        "`flygym`. The studio's own interpreter cannot hold it, because FlyGym installs MuJoCo " <>
        "3.16 and this application is pinned to 4.0.1"
    end
  end

  @doc """
  A body from what the run knows to build one.

  Options: `:python` — the interpreter, `#{@python}` when it is left out;
  `:name` — where to register the process that owns the body.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      python: Keyword.get(options, :python) || interpreter!(),
      name: Keyword.get(options, :name),
      sensors: Keyword.get(options, :sensors, @sensors)
    }
  end

  @impl true
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: {map(), map(), t()}
  def step(body, actions) do
    body = start(body)

    case Environment.step(body.port, actions) do
      {:ok, observations, proprioceptive_state} ->
        {observations, proprioceptive_state, body}

      {:error, reason} ->
        raise ArgumentError, "the fly's body did not step: #{inspect(reason)}"
    end
  end

  @impl true
  @spec reset(t()) :: t()
  def reset(body) do
    body = start(body)

    case Environment.reset(body.port) do
      {:ok, _episode} -> body
      {:error, reason} -> raise ArgumentError, "the fly's body did not reset: #{inspect(reason)}"
    end
  end

  @impl true
  @spec stop(t()) :: :ok
  def stop(nil), do: :ok
  def stop(%__MODULE__{port: nil}), do: :ok

  def stop(%__MODULE__{port: port}) do
    # The process may already be down with the run that owned it; asking a dead
    # process to stop would report a failure that has already happened.
    if Process.alive?(port), do: Environment.stop(port), else: :ok
  end

  @impl true
  # The body starts where its own gait stands it up and is moved only by the
  # actions a policy chose: there is no positioning procedure for a fly's walk.
  @spec positions_itself?() :: false
  def positions_itself?, do: false

  @impl true
  @spec primary_target(t()) :: nil
  def primary_target(%__MODULE__{}), do: nil

  @impl true
  @spec semantic_id_to_label(t()) :: %{}
  def semantic_id_to_label(%__MODULE__{}), do: %{}

  defp start(%__MODULE__{started?: true} = body), do: body

  defp start(%__MODULE__{} = body) do
    # `Port.Environment` takes the executable first and its arguments after it,
    # so the interpreter and the peer script are one command.
    options = [command: [body.python, script_path()], sensor_ids: body.sensors]

    options = if body.name, do: Keyword.put(options, :name, body.name), else: options

    case Environment.start_link(options) do
      {:ok, port} -> %{body | port: port, started?: true}
      {:error, reason} -> raise ArgumentError, "the fly's body did not start: #{inspect(reason)}"
    end
  end

  defp installed_interpreter do
    path = installed_path()
    if File.exists?(path), do: path, else: nil
  end

  defp interpreter! do
    interpreter() ||
      raise ArgumentError, unavailable_reason()
  end

  defp script_path do
    :ex_tbp_monty |> :code.priv_dir() |> Path.join("monty_py") |> Path.join(@script)
  end
end
