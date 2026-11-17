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
  alias Monty.Config.Source
  alias Monty.Studio
  alias Monty.Studio.Cad.Preparation

  # The corpus manifests this application ships, one per object set.
  @corpora "monty_experiments/sets/*/*.json"

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
  """
  @spec run(String.t(), (progress() -> any())) :: {:ok, [String.t()]} | {:error, String.t()}
  def run("cad_part_memories", notify) do
    plans = cad_plans()
    total = length(plans)

    if plans == [] do
      {:error, "no CAD experiment here names a part a memory could be taught on"}
    else
      plans
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {plan, index}, {:ok, said} ->
        notify.(%{index: index, total: total, what: "#{plan.part}: memory and meshes"})

        case Preparation.prepare(plan) do
          {:ok, written} ->
            {:cont,
             {:ok,
              said ++ ["#{plan.part}: #{written.written} object(s), #{written.nodes} node(s)"]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # The manifest is this application's own file, found under its priv.
  # sobelow_skip ["Traversal.FileModule"]
  def run("objaverse_dogs", notify) do
    with {:ok, corpus, file} <- corpus("objaverse_dogs") do
      objects = file |> File.read!() |> JSON.decode!() |> Map.fetch!("objects")
      into = Path.join([Monty.Prerequisites.root_path("MONTY_DATA"), "mujoco/objects", corpus])
      cache = Path.join(Monty.Prerequisites.root_path("MONTY_DATA"), "downloads/#{corpus}")
      total = length(objects)

      with :ok <- fetch(objects, cache, notify) do
        notify.(%{index: total, total: total, what: "importing #{total} object(s)"})

        case Import.import(cache, objects, into) do
          {:ok, rows} -> {:ok, ["#{corpus}: #{length(rows)} object(s) in #{into}"]}
          {:error, reason} -> {:error, "could not import #{corpus}: #{inspect(reason)}"}
        end
      end
    end
  end

  def run(name, _notify), do: {:error, "unknown build #{inspect(name)}"}

  # -- the CAD parts -------------------------------------------------------

  # One plan per CAD experiment this application defines: the experiment says
  # which part it steps and which memory it loads, and every part it names is a
  # memory this build writes. That is what lets several recognition experiments
  # run against memories of several parts.
  defp cad_plans do
    Path.wildcard(Path.join([extra_root(), "sets", "cad", "conf", "experiment", "cad", "*.yaml"]))
    |> Enum.map(&"cad/#{Path.basename(&1, ".yaml")}")
    |> Enum.flat_map(fn experiment ->
      with {:ok, opened} <- Studio.open(experiment, conf_dir: Source.conf_dirs()),
           {:ok, plan} <- Preparation.plan(opened.setup) do
        [plan]
      else
        _nothing_to_teach -> []
      end
    end)
    |> Enum.uniq_by(& &1.memory)
  end

  # -- the corpus ----------------------------------------------------------

  # sobelow_skip ["Traversal.FileModule"]
  defp corpus(name) do
    case Enum.find(corpora(), &(elem(&1, 0) == name)) do
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
  defp corpora do
    Path.wildcard(Path.join(extra_root(), @corpora))
    |> Enum.filter(&corpus?/1)
    |> Enum.map(fn file ->
      name = file |> Path.basename(".json")

      {name, file}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
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
  # `into` is the cache directory under the data root, built here.
  # sobelow_skip ["Traversal.FileModule"]
  defp fetch(objects, into, notify) do
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

        case fetch_glb(object, path) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
  end

  # `path` is that cache plus the uid the corpus manifest names.
  # sobelow_skip ["Traversal.FileModule"]
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

  defp extra_root, do: Path.join(priv(), "monty_experiments")

  defp priv do
    case :code.priv_dir(:ex_tbp_monty) do
      {:error, _reason} -> "priv"
      dir -> List.to_string(dir)
    end
  end
end
