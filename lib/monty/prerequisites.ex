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

  alias Monty.Prerequisites.Saga

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
          optional(:extract) => boolean(),
          optional(:unpacks_to) => String.t() | nil
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

  @doc """
  Whether a prerequisite is already in place.

  For an archive that is unpacked, "in place" is the *directory it fills*, not
  the archive: an archive sitting on disk with nothing unpacked beside it is a
  download that was interrupted, and a page that called it present would be
  telling a reader their data is there when no run can read it.
  """
  @spec present?(prerequisite()) :: boolean()
  def present?(%{extract: true} = prerequisite),
    do: holds_something?(where_it_lands(prerequisite))

  def present?(prerequisite), do: File.exists?(target_path(prerequisite))

  # A directory that exists and holds nothing is not data: it is the `mkdir` on
  # the way to some, or an unpack that was interrupted. Counting it as present is
  # how a page says "ready" and the world then answers "Unknown object type:
  # mug" — a sentence about an object, when the truth is about the bundle nobody
  # fetched.
  defp holds_something?(path) do
    case File.ls(path) do
      {:ok, []} -> false
      {:ok, _entries} -> true
      {:error, _reason} -> false
    end
  end

  @doc "Whether the file itself is on disk, unpacked or not."
  @spec downloaded?(prerequisite()) :: boolean()
  def downloaded?(prerequisite), do: File.exists?(target_path(prerequisite))

  @typedoc """
  What a prerequisite takes up: the archive as it arrived, and what it unpacked
  to.

  `nil` where the thing is not there, which a page shows as "not yet" rather
  than as zero: an archive that is absent and one that is empty are different
  answers, and `0 B` for both is the shape of a page lying about a download.
  """
  @type size :: %{archive: non_neg_integer() | nil, unpacked: non_neg_integer() | nil}

  @doc """
  How much disk this prerequisite takes.

  Read off the filesystem, so it answers for a machine that has just started and
  for one prepared by hand — a saga need not be running, or ever have run, for a
  person to ask "how big is this?". Costs one walk of the directory an archive
  fills; a release of ten objects is a few hundred files.
  """
  @spec size(prerequisite()) :: size()
  def size(prerequisite) do
    %{
      archive: file_size(target_path(prerequisite)),
      unpacked: if(prerequisite[:extract], do: directory_size(where_it_lands(prerequisite)))
    }
  end

  defp file_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size
      _absent_or_a_directory -> nil
    end
  end

  defp directory_size(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(path, &1))
        |> Enum.reduce(0, fn entry, total -> total + entry_size(entry) end)

      {:error, _absent} ->
        nil
    end
  end

  # `lstat`, not `stat`: a link is followed by the page that opens it, and a
  # walk that follows links is a walk that can circle.
  defp entry_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> directory_size(path) || 0
      {:ok, %File.Stat{type: :regular, size: size}} -> size
      _a_link_or_unreadable -> 0
    end
  end

  @doc """
  The bundles the manifest names that are not on this machine yet.

  A release starts without them — the UI comes up first and the download is a
  decision, not a boot step — so every page that can say "a run needs this" asks
  here rather than assuming a prepared volume.
  """
  @spec missing() :: [prerequisite()]
  def missing, do: Enum.reject(all(), &present?/1)

  @doc """
  The bundles with work left in them: not here at all, or here without what a
  run reads.

  Wider than `missing/0` on purpose. An archive that arrived and was unpacked
  has a *memory* a run reads, exported from its pickles — and an archive whose
  pickles are on disk and whose libraries are not is not missing, it is
  unfinished. That difference is what let a machine report every prerequisite
  as downloaded while a run still had nothing to recognise with.

  The judgement is `Saga.ready?/1`, the same derivation the machine itself uses,
  so the boot and the page cannot disagree about what is left.
  """
  @spec unfinished() :: [prerequisite()]
  def unfinished, do: Enum.reject(all(), &Saga.ready?/1)

  @doc """
  Downloads one prerequisite and waits for it, answering how it ended.

  The download runs in a process of its own and reports on
  `Monty.Prerequisites.Saga.topic()`; this is the waiting half, so the page,
  `mix monty.prerequisites.fetch` and the release command that fetches before a
  container serves all see the same download rather than three of them.

  A download that is already running is joined, not started twice. A fetch that
  cannot be started is answered with the reason rather than raised: a boot
  fetches several in a row, and the one that cannot start is no reason for the
  others not to.
  """
  @spec fetch(prerequisite()) :: {:ok, Saga.progress()} | {:error, term()}
  def fetch(prerequisite) do
    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Saga.topic())

    case Saga.start(prerequisite) do
      {:ok, _pid} -> await(prerequisite)
      {:ok, _pid, _value} -> await(prerequisite)
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :not_started}
    end
  end

  defp await(prerequisite) do
    receive do
      {:download, %{id: id, status: :done} = progress} when id == prerequisite.id ->
        {:ok, progress}

      {:download, %{id: id, status: status} = progress}
      when id == prerequisite.id and status in [:failed, :cancelled] ->
        {:error, Map.get(progress, :error) || status}

      {:download, %{id: id}} when id == prerequisite.id ->
        await(prerequisite)
    after
      :timer.minutes(30) -> {:error, :timeout}
    end
  end

  # Where an archive unpacks to. An entry says so when the archive's name is not
  # the directory it fills (`ycb_objects_1.0.tgz` fills `ycb/`); otherwise the
  # archive's name without its suffix is the directory, which is what `tar xf`
  # does with it.
  @spec where_it_lands(prerequisite()) :: Path.t()
  def where_it_lands(%{unpacks_to: to} = prerequisite) when is_binary(to),
    do: Path.join(root_path(prerequisite.root), to)

  def where_it_lands(%{root: root, target: target}) do
    Path.join(root_path(root), Path.rootname(target))
  end

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

  # MuJoCo has no engine to check: its package travels in the interpreter this
  # application carries, by construction. What it does need is the dataset and
  # the memory — the two downloads — so those are what a page names.
  def for_setup(%{world: :mujoco} = setup), do: data_need(setup) ++ models_need(setup)

  def for_setup(%{world: :habitat} = setup) do
    engine_need(setup) ++ data_need(setup) ++ models_need(setup)
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
    key = {@engine_memo, imports_asker(), package(engine)}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        answer = imports?(package(engine))
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

  @doc """
  Drops the memoised engine answers. The suite calls this: `:persistent_term` is
  not rolled back between tests, and one test's answer would be the next one's.
  """
  @spec forget_engines() :: :ok
  def forget_engines do
    for engine <- [:mujoco, :habitat] do
      :persistent_term.erase({@engine_memo, imports_asker(), package(engine)})
    end

    :ok
  end

  @doc "The interpreter the peer runs on: `MONTY_PYTHON`, or `python3` on the PATH."
  @spec python() :: String.t() | nil
  def python, do: System.get_env("MONTY_PYTHON") || System.find_executable("python3")

  @doc """
  What a reader can do about a missing need.

  Two kinds, and only one of them is a download. A dataset or a pretrained
  memory is fetched on `/prerequisites`; an interpreter is configuration
  (`MONTY_PYTHON`) and an engine is a package inside that interpreter. A page
  that offers a download button for either is offering something that does not
  exist, so the kinds are named here instead of guessed at in a template.
  """
  @spec remedy(need()) :: :download | :configure
  def remedy(%{kind: kind}) when kind in [:data, :models], do: :download
  def remedy(_need), do: :configure

  @doc """
  Whether an operator named the interpreter, rather than the page falling back
  to `python3` on the PATH.

  The difference is the whole answer to "is MuJoCo here?": a machine can have an
  interpreter with Monty and MuJoCo in it and still have a PATH `python3` that
  has neither, and a page that cannot tell the two apart blames the engine for
  the configuration.
  """
  @spec python_configured?() :: boolean()
  def python_configured?, do: System.get_env("MONTY_PYTHON") not in [nil, ""]

  @doc """
  The package an engine's own code lives in.

  Public because two different interpreters are asked about it: the one the
  world runs in (`engine_installed?/1`) and the one this application carries.
  """
  @spec package(:mujoco | :habitat) :: String.t()
  def package(:mujoco), do: "mujoco"
  def package(:habitat), do: "habitat_sim"

  # Which interpreter answers "can this import?".
  #
  # It is the one this application *carries*: `config/pythonx.exs` is where the
  # build installs packages, so MuJoCo is in it by construction and the answer
  # travels with the release. The fallback asks an interpreter an operator named,
  # which is the right question for a script and the wrong one for a page — a
  # machine with MuJoCo installed came to be told it had none because the page
  # asked `python3` on the PATH.
  defp imports_asker do
    Application.get_env(
      :ex_tbp_monty,
      :python_imports?,
      {__MODULE__, :importable_in_environment}
    )
  end

  defp imports?(module) do
    case imports_asker() do
      {module_name, function} -> apply(module_name, function, [module])
      function when is_function(function, 1) -> function.(module)
    end
  end

  @doc """
  Whether the interpreter an operator named can import a module.

  What the engine check asks when a deployment has no interpreter of its own to
  point at. It needs `MONTY_PYTHON` (or a `python3` on the PATH) to exist and be
  executable, and answers `false` for both failures rather than raising in a
  render.
  """
  @spec importable_in_environment(String.t()) :: boolean()
  def importable_in_environment(module) when is_binary(module), do: importable?(module)

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
      # An engine is a package inside the interpreter the world runs in, and that
      # interpreter is the one `MONTY_PYTHON` names. Without it there is nothing
      # to answer for: "MuJoCo is missing" about a `python3` nobody chose is how a
      # machine with MuJoCo installed came to be told it had none.
      engine when not is_nil(engine) ->
        [
          %{
            kind: :engine,
            what: "#{engine_name(engine)}, which the world steps",
            path: nil,
            present?: engine_installed?(engine)
          }
        ]

      nil ->
        []
    end
  end

  defp engine_name(:mujoco), do: "MuJoCo"
  defp engine_name(:habitat), do: "Habitat-Sim"

  defp data_need(%{environment: %{data_path: path}}) when is_binary(path) and path != "" do
    [
      %{
        kind: :data,
        what: "the objects this environment loads",
        path: path,
        present?: holds_something?(path)
      }
    ]
  end

  # An environment that names no data path reads no objects — a supervised run
  # over a pretrained memory does not touch the disk for them.
  defp data_need(_setup), do: []

  # What a run reads is the library this application exports, not the archive it
  # was exported from. Asking about the model's directory answered a different
  # question — "are the pickles here?" — and said yes on a volume where nothing
  # had ever been exported, so the page showed a run as possible and the first
  # step failed with "no memory this application can read".
  defp models_need(%{model_name_or_path: path}) when is_binary(path) and path != "" do
    name = Monty.Studio.Memory.name_of(path)
    release = Monty.Studio.Memory.release_of(path)

    cond do
      name == nil ->
        []

      release == nil ->
        # A config that names a model but not the release it was trained from:
        # a library from any release satisfies it, and the path worth naming is
        # the directory the memory would be exported from.
        [
          %{
            kind: :models,
            what: "the pretrained memory this config names",
            path: memory_path(path),
            present?: Monty.Studio.Memory.releases_for(name) != []
          }
        ]

      true ->
        memory = Monty.Studio.Memory.path_for(name, release)

        [
          %{
            kind: :models,
            what: "the pretrained memory this config names",
            path: memory,
            present?: File.exists?(memory)
          }
        ]
    end
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
      extract: Map.get(entry, "extract", false),
      unpacks_to: Map.get(entry, "unpacks_to")
    }
  end
end
