defmodule Monty.Studio.Learned do
  @moduledoc """
  What a run that trained leaves behind, in the run's own directory.

  Monty's `save_state_dir/1` writes the pretrained model at the end of a
  pretraining phase. Without it, what a training phase learned dies with the
  process that built it: the evaluation phase after it, and the next run of the
  same experiment, would start from the pretrained graphs again.

  Two things run an experiment — the queue's worker (`Monty.Studio.Jobs.Run`)
  and `mix monty.run` — and a memory that only one of them keeps is a memory a
  reader loses by choosing a different door. So the writing lives here, and each
  runner says the sentences this returns in its own voice: a worker appends them
  to the run's log, the command line prints them.

  It goes in two places: the run's own directory, so what this run left behind is
  still recognisable as this run's, and the library tree, because that is where a
  later config looks — a run that trained is only useful if the memory it built is
  one the next config can load. Both are in the format the pretrained libraries
  are in, so anything that can read one can read the other, and a model of several
  modules is one library with an index per module rather than one library a module
  (`Memory.save_all/4`).
  """

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Studio.{Artifacts, Memory}

  @release "trained"

  @typedoc """
  What an experiment's phases are, as `Setup.epoch_plan/1` answers them: which
  mode, and how many epochs of it.
  """
  @type plan :: [{:train | :eval, non_neg_integer()}]

  @doc "The release these memories are filed under, inside the run's directory."
  @spec release() :: String.t()
  def release, do: @release

  @doc """
  Writes every module's memory, and returns the lines that describe what it did.

  Two places, and both matter. The run's own directory keeps what *this* run
  left behind — provenance, and what the page points at. The library tree is
  where a later config looks (`Setup.memory_for/2` asks `Memory.load_module/3`),
  so a run that trained is only useful if its memory is there too: without it,
  "train it" trains and the evaluation config that reads that memory still says
  it has none.

  The release it is filed under is `trained` — not a Monty release, so a config
  can never name it by accident, and `Memory.releases_for/1` finds it for a
  config that names the memory without a release of ours.

  A run with no record has nowhere to put them — a throwaway run keeps nothing —
  and a plan with no training phase learned nothing that outlives it: both answer
  `[]`, which says nothing rather than saying that something failed.

  A **part** of a parallel training run keeps its memory in its own directory and
  leaves the library tree alone (`library: false`): the library is what the parts
  learned *between* them, and one part writing it as it finishes would overwrite
  the merged one with its own share
  (`Monty.Studio.Memories`).
  """
  @spec keep(binary() | nil, map(), plan(), %{optional(term()) => term()}, keyword()) ::
          [String.t()]
  def keep(run_id, opened, plan, memories, options \\ [])

  def keep(nil, _opened, _plan, _memories, _options), do: []

  def keep(run_id, opened, plan, memories, options) do
    if trains?(plan), do: keep_run(run_id, opened, memories, options), else: []
  end

  @doc "Where a run's memories are written."
  @spec dir(binary()) :: Path.t()
  def dir(run_id), do: Path.join(Artifacts.dir(run_id), "memory")

  @doc """
  What the memories hold: the objects they know, and the nodes behind them.

  This is the one number a training run has to show for itself. A matching run is
  judged by evidence climbing per object; a training run matches nothing and
  reports no evidence at all — what changes as it steps is the memory, so the
  memory is what a reader is told about. It costs nothing extra here: the runner
  has the memories in hand at the end of a training episode anyway, and copying
  them out is what `Run.memories/1` charges for.

  A module that keeps no graph memory is not counted: it holds nothing.
  """
  @spec size(%{optional(term()) => term()}) :: %{
          objects: non_neg_integer(),
          nodes: non_neg_integer()
        }
  def size(memories) do
    graphs = for {_module_id, %GraphMemory{} = memory} <- memories, do: memory

    objects = graphs |> Enum.flat_map(&GraphMemory.get_memory_ids/1) |> Enum.uniq()

    nodes =
      graphs
      |> Enum.flat_map(fn memory ->
        for graph_id <- GraphMemory.get_memory_ids(memory),
            do: GraphMemory.get_num_nodes_in_graph(memory, graph_id, nil)
      end)
      |> Enum.sum()

    %{objects: length(objects), nodes: nodes}
  end

  @doc """
  The same, as the sentence a run says after a training episode.

  Words rather than numbers only, because this is what a person reads while
  watching a run learn: "2 objects and 3 456 nodes" answers what is happening to
  it, where "nodes: 3456" is a field.
  """
  @spec growth_line(%{optional(term()) => term()}) :: String.t()
  def growth_line(memories) do
    %{objects: objects, nodes: nodes} = size(memories)

    "the memory now holds #{count(objects, "object")} and #{count(nodes, "node")}"
  end

  defp count(1, noun), do: "1 " <> noun

  defp count(number, noun) do
    number |> Humanizer.delimit() |> Kernel.<>(" " <> noun <> "s")
  end

  defp trains?(plan), do: Enum.any?(plan, fn {mode, _epochs} -> mode == :train end)

  # A module that keeps no graph memory — the stand-in learning module a config
  # without an evidence model gets — has nothing to write, and the `shell`
  # finding already says so.
  defp keep_run(run_id, opened, memories, options) do
    learned =
      opened.setup.learning_modules
      |> Enum.with_index()
      |> Enum.flat_map(fn {module, index} ->
        case Map.get(memories, module.id) do
          %GraphMemory{} = memory -> [{index, module.id, memory}]
          _none -> []
        end
      end)

    case learned do
      [] -> []
      learned -> write(run_id, name_for(opened), learned, Keyword.get(options, :library, true))
    end
  end

  defp write(run_id, name, learned, library?) do
    indexed = Enum.map(learned, fn {index, _module_id, memory} -> {index, memory} end)

    with :ok <- Memory.save_all(indexed, name, @release, dir(run_id)),
         :ok <- write_library(indexed, name, library?) do
      ["#{subject(learned)} is the library #{name} (#{@release}), #{where(run_id, library?)}"]
    else
      {:error, reason} ->
        # A memory that could not be written is worth a sentence, not a crash: the
        # run itself concluded, and what is lost is what comes after it.
        ["the memory #{name} could not be written: #{inspect(reason)}"]
    end
  end

  defp write_library(_indexed, _name, false), do: :ok

  defp write_library(indexed, name, true),
    do: Memory.save_all(indexed, name, @release, Memory.libraries_dir())

  defp where(run_id, true), do: "in #{dir(run_id)} and in the libraries"

  defp where(run_id, false),
    do: "in #{dir(run_id)}; the whole batch's memory is written once its parts are merged"

  # One module's memory is that module's; several are the model's, and the model
  # is what the file is named after.
  defp subject([{_index, module_id, _memory}]), do: "the memory #{module_id} learned"

  defp subject(learned) do
    "the memory #{count(length(learned), "module")} learned"
  end

  # The name the run's own memory is filed under: the model its config names,
  # which is what a later run of that config would ask for, and the run's own
  # name when it names none. The model's name and not the module's, because that
  # is the name the *next* config asks for: a run that filed
  # `dist_agent_5lm_2obj_train-learning_module_0` … `_4` left five libraries the
  # evaluation config of the same tutorial never asked for.
  #
  # Public because a batch's merged memory is filed under the same name
  # (`Monty.Studio.Memories`): the parts of a parallel training run are one
  # library when they are put back together, and two names for one model would be
  # one library the next config does not find.
  @doc "The library a run of this experiment writes its memory under."
  @spec name_for(map()) :: String.t()
  def name_for(opened) do
    case Memory.name_of(opened.setup.model_name_or_path) ||
           sanitise(opened.setup.logging.run_name) || sanitise(opened.name) do
      nil -> "monty-memory"
      name -> name
    end
  end

  # A file name, from a config's own words: anything that is not a letter, a
  # digit, an underscore, a dot or a dash becomes a dash. A name that has nothing
  # of that left — the empty run name most of Monty's test configs have — is no
  # name, so the next one is asked for instead of filing a memory under `""`.
  defp sanitise(nil), do: nil

  defp sanitise(name) do
    case name |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-") |> String.trim("-") do
      "" -> nil
      file_name -> file_name
    end
  end
end
