defmodule Monty.Prerequisites.Build do
  @moduledoc """
  The prerequisites this application **makes**, rather than downloads.

  Two of the things a run reads cannot arrive as an archive. A dogs experiment
  steps an object set imported from Objaverse's own GLBs, and a CAD experiment
  compares a mesh against a memory taught on a STEP file. Both are outputs of
  code this application carries, so `/prerequisites` offers them as a click —
  through the same machine a download goes through, so the row, the badge, the
  progress, Cancel and the record between starts are the same, and a build that
  takes a minute does not hold a page.

  A manifest entry names one with `build:` instead of `url:`. It is never
  started by a boot (`Monty.Prerequisites.unfinished/0` skips builds): a
  download is a file somebody published, a build is minutes of this machine's
  work, and only a person asks for that.

  ## What each build writes

  Nothing here invents a format or a path. The CAD build is the plan each CAD
  experiment gives (`Monty.Studio.Cad.Preparation`), which reads the config's
  own `object_names`, `model_name_or_path` and `data_path` — so a new part is a
  new config and no code. The corpus build is the manifest that ships beside the
  experiments that step it.
  """

  alias ExTbpMonty.Objaverse.Import
  alias Monty.Studio
  alias Monty.Studio.Cad.Generate
  alias Monty.Studio.Cad.Preparation
  alias Monty.Studio.Catalog

  # The corpus manifests this application ships, one per object set, under the
  # experiments root `extra_root/0` answers.
  @corpora "sets/*/*.json"

  # Objaverse's GLBs, one file per object, at the address its own dataset names.
  @glb "https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs"

  @doc """
  The builds `build:` may name.

  A closed list, because a manifest is data: a typo in it has to fail at the
  click with a sentence, not silently do nothing.
  """
  @spec names() :: [String.t()]
  def names, do: ~w(cad_part_memories objaverse_dogs)

  @typedoc "What a build is doing: which step of how many, and what."
  @type progress :: %{index: pos_integer(), total: pos_integer(), what: String.t()}

  @doc """
  Runs the build `name` names and answers what it wrote.

  `notify` is called with a `t:progress/0` as each step starts, so the row says
  which part or which dog it is on rather than sitting at "building" for a
  minute.

  The pieces a run reaches outside itself — the plans, the meshing, the download,
  the import — are named rather than called, so a test drives this state without
  geometry or a network, exactly as `Monty.Prerequisites.Saga`'s `:builder` and
  `:fetcher` do.
  """
  @spec run(String.t(), (progress() -> any()), keyword()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def run(name, notify, opts \\ [])

  def run("cad_part_memories", notify, opts), do: cad_memories(notify, opts)
  def run("objaverse_dogs", notify, opts), do: corpus_import("objaverse_dogs", notify, opts)
  def run(name, _notify, _opts), do: {:error, "unknown build #{inspect(name)}"}

  @doc """
  The memories this machine would teach: one per CAD experiment it defines.

  Public because it is the answer to "what would this click make?", and because
  it is the half of a build that needs no geometry to ask.
  """
  @spec plans() :: [map()]
  def plans, do: cad_plans()

  @doc """
  The memories the click for `build` would write, by path.

  A build this application makes has plans; a corpus does not. A page asks this
  to name what a click writes *beyond* what the manifest promises — a part a
  person brought is planned from their own experiment, and the manifest, written
  before the part existed, cannot promise it.

  Read off the generated sets' own experiment files, not by composing every plan:
  a plan composes each experiment and stats each part (~150 ms for the CAD sets),
  which is more than a render can pay, and what a row needs to say is the name.
  """
  @spec planned_memories(String.t()) :: [Path.t()]
  def planned_memories("cad_part_memories"), do: Generate.memories()
  def planned_memories(_build), do: []

  # -- the CAD parts -------------------------------------------------------

  # One memory per CAD experiment this application defines, taught from the part
  # its config names.
  defp cad_memories(notify, opts) do
    plans = plans(opts)
    total = length(plans)

    if plans == [] do
      {:error, "no CAD experiment here names a part a memory could be taught on"}
    else
      plans
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {plan, index}, {:ok, said} ->
        notify.(%{index: index, total: total, what: "#{label(plan)}: memory and meshes"})

        case prepare(plan, opts) do
          {:ok, written} ->
            {:cont,
             {:ok,
              said ++
                [
                  "#{label(plan)}: #{written.written} object(s), #{written.nodes} node(s)" <>
                    how(written)
                ]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Whether this click had to teach it. A memory the same part file and optics
  # already produced is left as it is, and the row says so rather than reporting
  # a one-second step as if it had done ten minutes of geometry
  # (`Monty.Studio.Cad.Preparation.prepare/2`).
  defp how(%{taught: :before}), do: " — already taught from the same inputs"
  defp how(_taught_now), do: ""

  # What the row says the step is about. A memory of several parts names all of
  # them — the set's row would otherwise say "plate" while the blend is being
  # taught too, which is the one thing that row is for.
  defp label(%{parts: parts}), do: Enum.map_join(parts, ", ", &elem(&1, 0))
  defp label(%{part: part}), do: part

  # -- the corpus ----------------------------------------------------------

  # The manifest beside the cards that step it, read to learn which objects it
  # names.
  # sobelow_skip ["Traversal.FileModule"]
  defp corpus_import(name, notify, opts) do
    with {:ok, corpus, file} <- corpus(name, opts) do
      objects = file |> File.read!() |> JSON.decode!() |> Map.fetch!("objects")
      data = Monty.Prerequisites.root_path("MONTY_DATA")
      into = Path.join([data, "mujoco/objects", corpus])
      cache = Path.join(data, "downloads/#{corpus}")
      total = length(objects)

      with :ok <- fetch(objects, cache, notify, opts) do
        notify.(%{index: total, total: total, what: "importing #{total} object(s)"})

        case import(cache, objects, into, opts) do
          {:ok, rows} -> {:ok, ["#{corpus}: #{length(rows)} object(s) in #{into}"]}
          {:error, reason} -> {:error, "could not import #{corpus}: #{inspect(reason)}"}
        end
      end
    end
  end

  # Every CAD experiment this machine can teach, from every CAD set it has: the
  # sets the application ships and the ones a person generated
  # (`Monty.Studio.Cad.Generate`), which live in their own root beside them.
  # Each set's `conf` is a config root, so an experiment is opened through its
  # own set first and the shipped tree behind it — the overlay every config is
  # read with.
  #
  # A CAD experiment with nothing to teach — no `model_name_or_path`, a part this
  # application does not carry — is skipped rather than failed: the click makes
  # what it can, and the page's Checks are where a broken config is reported.
  defp cad_plans do
    roots = cad_set_roots() ++ Catalog.conf_dirs()

    roots
    |> cad_experiment_names()
    |> Enum.flat_map(&plan_for(roots, &1))
    |> Enum.uniq_by(& &1.memory)
  end

  # The `conf` of every set under the roots the sets live in. The shipped tree
  # answers the same directories through `Source.extra_conf_dirs/0`; a generated
  # set is the one that does not, and this is where it is picked up.
  defp cad_set_roots do
    [Generate.sets_dir(), Path.join(extra_root(), "sets")]
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*/conf")))
    |> Enum.filter(&File.dir?/1)
  end

  defp cad_experiment_names(roots) do
    folder = Generate.folder()

    for root <- roots,
        file <- Path.wildcard(Path.join([root, "experiment", folder, "*.yaml"])),
        uniq: true,
        do: "#{folder}/#{Path.basename(file, ".yaml")}"
  end

  # The experiment says which part it steps and which memory it loads, and every
  # part it names is a memory this build writes. That is what lets several
  # recognition experiments run against memories of several parts.
  defp plan_for(roots, experiment) do
    with {:ok, opened} <- Studio.open(experiment, conf_dir: roots),
         {:ok, plan} <- Preparation.plan(opened.setup),
         false <- Preparation.trained?(plan) do
      [plan]
    else
      _nothing_to_teach -> []
    end
  end

  # -- the corpus ----------------------------------------------------------

  # The manifest found by `corpus/2`, out of the ones this application ships.
  # sobelow_skip ["Traversal.FileModule"]
  defp corpus(name, opts) do
    case Enum.find(corpora(opts), &(elem(&1, 0) == name)) do
      nil ->
        {:error, "no corpus manifest here is called #{inspect(name)}"}

      {_corpus, file} ->
        with {:ok, document} <- file |> File.read!() |> JSON.decode() do
          {:ok, Map.get(document, "corpus", name), file}
        end
    end
  end

  # A corpus manifest is a JSON document beside the cards that step it, with an
  # `objects` list naming the GLBs to fetch.
  defp corpora(opts) do
    Path.wildcard(Path.join([root(opts), @corpora]))
    |> Enum.filter(&corpus?/1)
    |> Enum.map(fn file ->
      name = file |> Path.basename(".json")

      {name, file}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  # A manifest this application ships, on the experiments root; the path is the
  # one wildcard answered with, not a request's.
  defp corpus?(file) do
    with {:ok, text} <- File.read(file),
         {:ok, document} <- JSON.decode(text) do
      is_list(Map.get(document, "objects"))
    else
      _not_a_manifest -> false
    end
  end

  # One file per object, cached: a second build fetches nothing, and an
  # interrupted one resumes at the next missing file.
  # sobelow_skip ["Traversal.FileModule"]
  # The cache is the corpus's own folder under the data root, and its name is the
  # manifest's.
  defp fetch(objects, into, notify, opts) do
    File.mkdir_p!(into)
    {:ok, _} = Application.ensure_all_started(:req)
    total = length(objects)

    objects
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {object, index}, :ok ->
      path = Path.join(into, object["uid"] <> ".glb")

      if File.exists?(path) do
        {:cont, :ok}
      else
        notify.(%{index: index, total: total, what: object["name"]})

        case glb(object, path, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, download_refused(object, reason)}}
        end
      end
    end)
  end

  # A refusal is a sentence about one object, not a bare reason: the row a person
  # reads has to say which object never arrived, and the reason a getter answers
  # with may be an atom of its own.
  defp download_refused(object, reason) do
    "#{object["name"]}: the download failed (#{if is_binary(reason), do: reason, else: inspect(reason)})"
  end

  defp glb(object, path, opts),
    do: Keyword.get_lazy(opts, :glb, fn -> getter() end).(object, path)

  # The download is named rather than called, as the plans and the import are: a
  # case that says "the network refused" has to reach that refusal on a machine
  # that has a network, and `:glb_getter` is how it takes the network's place.
  defp getter, do: Application.get_env(:ex_tbp_monty, :glb_getter, &fetch_glb/2)

  # sobelow_skip ["Traversal.FileModule"]
  # The path is built from the manifest's own shard and uid, in the cache above.
  defp fetch_glb(object, path) do
    url = Enum.join([@glb, object["shard"], object["uid"] <> ".glb"], "/")

    case Req.get(url,
           decode_body: false,
           retry: :transient,
           max_retries: 2,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: body}} -> File.write(path, body)
      {:ok, %{status: status}} -> {:error, "GET #{url} answered #{status}"}
      {:error, reason} -> {:error, "GET #{url} failed: #{inspect(reason)}"}
    end
  end

  # -- what a run reaches outside itself -----------------------------------

  defp plans(opts), do: Keyword.get_lazy(opts, :plans, &cad_plans/0)

  defp prepare(plan, opts),
    do: Keyword.get_lazy(opts, :prepare, fn -> &Preparation.prepare/1 end).(plan)

  defp import(cache, objects, into, opts),
    do: Keyword.get_lazy(opts, :import, fn -> &Import.import/3 end).(cache, objects, into)

  defp root(opts), do: Keyword.get_lazy(opts, :root, &extra_root/0)

  defp extra_root, do: Path.join(priv(), "monty_experiments")

  defp priv do
    case :code.priv_dir(:ex_tbp_monty) do
      {:error, _reason} -> "priv"
      dir -> List.to_string(dir)
    end
  end
end
