defmodule Monty.Prerequisites do
  @moduledoc """
  What Monty needs on disk before an experiment can run, and where it goes.

  The paths are Monty's own, not this application's: the same environment
  variables (`MONTY_DATA`, `MONTY_MODELS`, `MONTY_LOGS`) and the same defaults
  the Python tooling uses, so a checkout prepared here is usable there and the
  other way round. Nothing is downloaded from a made-up location — the manifest
  ships the URLs Monty's getting-started guide documents.

  The manifest is data (`priv/prerequisites.yaml`), so adding a prerequisite is
  an edit, not a code change.
  """

  @manifest "priv/prerequisites.yaml"

  # Where `engine_installed?/1` keeps its one answer per interpreter and package.
  @engine_memo {__MODULE__, :engine}

  @type prerequisite :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          optional(:description) => String.t() | nil,
          required(:url) => String.t(),
          required(:root) => String.t(),
          required(:target) => String.t(),
          optional(:sha256) => String.t() | nil,
          optional(:extract) => boolean()
        }

  @doc "Every configured prerequisite."
  @spec all(Path.t()) :: [prerequisite()]
  def all(manifest \\ manifest_path()) do
    {:ok, document} = YamlElixir.read_from_file(manifest)
    document |> Map.get("prerequisites", []) |> Enum.map(&stringify/1)
  end

  @doc "One prerequisite by id."
  @spec get(String.t(), Path.t()) :: prerequisite() | nil
  def get(id, manifest \\ manifest_path()), do: Enum.find(all(manifest), &(&1.id == id))

  @doc """
  The absolute path a prerequisite belongs at.

  Built from the environment variable its manifest entry names, so a shell
  that already exports `MONTY_MODELS` gets files where Monty expects them.
  """
  @spec target_path(prerequisite()) :: Path.t()
  def target_path(%{root: root, target: target}), do: Path.join(root_path(root), target)

  @doc """
  The directory an environment variable points at, with Monty's default.

  Monty's tooling reads the same three variables with the same defaults, so a
  shell that sets none of them still finds files where Monty expects them.
  """
  @spec root_default(String.t()) :: Path.t()
  def root_default("MONTY_DATA"), do: Path.expand("~/tbp/data")

  def root_default("MONTY_MODELS"),
    do: Path.expand("~/tbp/results/monty/pretrained_models")

  def root_default("MONTY_LOGS"), do: Path.expand("~/tbp/results/monty/projects")

  @doc "The directory an environment variable points at, with Monty's default."
  @spec root_path(String.t()) :: Path.t()
  def root_path("MONTY_DATA"), do: env_path("MONTY_DATA", "~/tbp/data")

  def root_path("MONTY_MODELS"),
    do: env_path("MONTY_MODELS", "~/tbp/results/monty/pretrained_models")

  def root_path("MONTY_LOGS"), do: env_path("MONTY_LOGS", "~/tbp/results/monty/projects")

  def root_path(root) when is_binary(root) do
    raise ArgumentError,
          "unknown prerequisite root #{inspect(root)}; expected MONTY_DATA, MONTY_MODELS or MONTY_LOGS"
  end

  @doc "Whether a prerequisite is already in place."
  @spec present?(prerequisite()) :: boolean()
  def present?(prerequisite), do: File.exists?(target_path(prerequisite))

  @typedoc """
  One file a run reads before it steps, and whether it is there.

  `what` is the sentence a page shows; `path` is where it belongs, so a reader
  can look for themselves rather than trusting a badge.
  """
  @type need :: %{
          required(:kind) => :interpreter | :engine | :data | :models,
          required(:what) => String.t(),
          optional(:path) => String.t() | nil,
          required(:present?) => boolean()
        }

  @doc """
  What a run of this setup reads off the disk, and whether each is there.

  Only the external process reads anything: the connector drives the simulator
  the config names, and that loads the objects its environment names and the
  pretrained memory its config names — from the same three directories a Python
  user puts them in. The stand-in steps a
  scene this port builds, and the memory the *ported* learning modules load ships
  inside the application (`priv/monty/libraries`), so a stand-in run needs
  nothing downloaded at all. That is the whole reason there is a stand-in.

  Nothing here is a guess about a name: the paths come out of the composed setup,
  which read them from the experiment's own config.

  Takes any map-shaped setup, struct or not — this module is the core, and
  `Monty.Studio.Setup` is the thing that already depends on it, so matching its
  fields is the dependency-free way to read them.
  """
  @spec for_setup(map()) :: [need()]
  def for_setup(%{world: :synthetic}), do: []

  def for_setup(%{world: :habitat} = setup) do
    [interpreter() | engine_need(setup)] ++ data_need(setup) ++ models_need(setup)
  end

  def for_setup(_setup), do: []

  @doc """
  Which engine a setup's own world runs: the simulator its environment names.

  A world is Monty's or this port's; which *engine* runs inside Monty's is the
  experiment's, and its config says so. `nil` when nothing is named — a config
  whose environment is not a simulator needs no engine of ours either.
  """
  @spec engine(map()) :: :mujoco | :habitat | nil
  def engine(%{environment: %{module: %{class: class}}}), do: engine_named(class)
  def engine(_setup), do: nil

  defp engine_named("MuJoCoSimulator"), do: :mujoco
  defp engine_named("HabitatEnvironment"), do: :habitat
  defp engine_named("HabitatSim"), do: :habitat
  defp engine_named(_other), do: nil

  @doc """
  Whether the interpreter can import an engine's own package.

  Asked once per interpreter and engine and remembered: the answer cannot change
  while the node runs, and a page that answers "is this available here?" should
  not pay for a subprocess on every render.
  """
  @spec engine_installed?(:mujoco | :habitat) :: boolean()
  def engine_installed?(engine) when engine in [:mujoco, :habitat] do
    key = {@engine_memo, python(), package(engine)}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        answer = importable?(package(engine))
        :persistent_term.put(key, answer)

        answer

      answer ->
        answer
    end
  end

  @doc """
  The engines a run could step, and whether this deployment has each.

  The page that answers "what is available here?" needs both halves: the engine
  a config names, and whether its package is in the interpreter.
  """
  @spec engines() :: [{:mujoco | :habitat, boolean()}]
  def engines, do: Enum.map([:mujoco, :habitat], &{&1, engine_installed?(&1)})

  @doc "The interpreter the peer runs on: `MONTY_PYTHON`, or `python3` on the PATH."
  @spec python() :: String.t() | nil
  def python, do: System.get_env("MONTY_PYTHON") || System.find_executable("python3")

  defp package(:mujoco), do: "mujoco"
  defp package(:habitat), do: "habitat_sim"

  # sobelow_skip ["CI.System"]
  # The command is the interpreter an operator named in `MONTY_PYTHON` — an
  # absolute path this process executes directly, with no shell and no argument
  # built from a request. Asking it to import a module is how the answer "is this
  # engine here?" is obtained rather than guessed.
  defp importable?(package) do
    case python() do
      nil ->
        false

      python ->
        executable?(python) and
          match?(
            {_out, 0},
            System.cmd(python, ["-c", "import #{package}"], stderr_to_stdout: true)
          )
    end
  end

  # A path a variable names is not an interpreter: a typo, a directory, or a file
  # somebody forgot to `chmod` would all fail at a run's first import, and asking
  # a page to spawn one fails harder still.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _not_a_program -> false
    end
  end

  defp engine_need(setup) do
    case engine(setup) do
      nil ->
        []

      engine ->
        [
          %{
            kind: :engine,
            what: "#{engine_name(engine)} itself (the `#{package(engine)}` package)",
            path: python(),
            present?: engine_installed?(engine)
          }
        ]
    end
  end

  defp engine_name(:mujoco), do: "MuJoCo"
  defp engine_name(:habitat), do: "Habitat-Sim"

  # The peer imports `tbp.monty` from `MONTY_PYTHON`; without it, `python3` is
  # almost never an interpreter that has Monty and MuJoCo installed, so the
  # variable is the honest check. The message says which one is being looked for
  # rather than a bare "missing".
  defp interpreter do
    case System.get_env("MONTY_PYTHON") do
      nil ->
        %{
          kind: :interpreter,
          what: "an interpreter with tbp.monty installed (MONTY_PYTHON is not set)",
          path: System.find_executable("python3"),
          present?: false
        }

      path ->
        %{
          kind: :interpreter,
          what: "the interpreter Monty runs in",
          path: path,
          present?: executable?(path)
        }
    end
  end

  defp data_need(%{environment: %{data_path: path}}) when is_binary(path) and path != "" do
    [
      %{
        kind: :data,
        what: "the objects this environment loads",
        path: path,
        present?: File.dir?(path)
      }
    ]
  end

  # An environment that names no data path reads no objects — a supervised run
  # over a pretrained memory does not touch the disk for them.
  defp data_need(_setup), do: []

  defp models_need(%{model_name_or_path: name}) when is_binary(name) and name != "" do
    [
      %{
        kind: :models,
        what: "the pretrained memory this config names",
        path: memory_path(name),
        present?: File.exists?(memory_path(name))
      }
    ]
  end

  defp models_need(_setup), do: []

  # A config that names an absolute path has already been resolved against
  # `MONTY_MODELS`; one that names a bare directory is relative to it. Guessing
  # the first case to be the second would send a reader to
  # `.../pretrained_models/Users/...`, a path nobody has.
  defp memory_path(name) do
    case Path.type(name) do
      :absolute -> name
      _relative -> Path.join(root_path("MONTY_MODELS"), name)
    end
  end

  @doc """
  The manifest this application ships, unless a test or an operator points
  somewhere else with `:prerequisites_manifest`.

  It is resolved through the application's priv directory rather than as the
  relative `priv/...` it names: a release keeps its priv somewhere other than the
  working directory, so a relative path works in a checkout and is "no such file"
  in the image. (What a *run writes* is the other way round — that belongs next
  to the working directory, see `Monty.Studio.Artifacts`.)
  """
  @spec manifest_path() :: Path.t()
  def manifest_path do
    Application.get_env(:ex_tbp_monty, :prerequisites_manifest, shipped_manifest())
  end

  defp shipped_manifest do
    case :code.priv_dir(:ex_tbp_monty) do
      {:error, _reason} -> @manifest
      dir -> dir |> List.to_string() |> Path.join("prerequisites.yaml")
    end
  end

  defp env_path(variable, default) do
    variable |> System.get_env(default) |> Path.expand()
  end

  defp stringify(entry) do
    %{
      id: Map.fetch!(entry, "id"),
      title: Map.fetch!(entry, "title"),
      description: Map.get(entry, "description"),
      url: Map.fetch!(entry, "url"),
      root: Map.fetch!(entry, "root"),
      target: Map.fetch!(entry, "target"),
      sha256: Map.get(entry, "sha256"),
      # An archive is unpacked where it lands: a prerequisite Monty's docs say
      # to unpack is not in place until it is unpacked.
      extract: Map.get(entry, "extract", false)
    }
  end
end
