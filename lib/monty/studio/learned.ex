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

  It goes in the run's own directory rather than in the library tree: a library
  is named by the experiment that loads it (`Monty.Studio.Memory.load/3`), and a
  run's output is named by the run. `memory/trained/<name>.jsonl.gz` is the
  format the pretrained libraries are in, so anything that can read one can read
  this.
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

  A run with no record has nowhere to put them — a throwaway run keeps nothing —
  and a plan with no training phase learned nothing that outlives it: both answer
  `[]`, which says nothing rather than saying that something failed.
  """
  @spec keep(binary() | nil, map(), plan(), %{optional(term()) => term()}) :: [String.t()]
  def keep(nil, _opened, _plan, _memories), do: []

  def keep(run_id, opened, plan, memories) do
    if trains?(plan) do
      Enum.flat_map(memories, &keep_one(run_id, opened, &1))
    else
      []
    end
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
  defp keep_one(_run_id, _opened, {_module_id, :none}), do: []

  defp keep_one(run_id, opened, {module_id, memory}) do
    path = dir(run_id)

    case Memory.save(memory, library_name(opened, module_id), @release, path) do
      :ok ->
        ["the memory #{module_id} learned is in #{path}"]

      {:error, reason} ->
        # A memory that could not be written is worth a sentence, not a crash: the
        # run itself concluded, and what is lost is what comes after it.
        ["the memory #{module_id} learned could not be written: #{inspect(reason)}"]
    end
  end

  # The name the run's own memory is filed under: the model its config names,
  # which is what a later run of that config would ask for, and the run's own
  # name when it names none. Two modules in one run are two memories, so the
  # module id keeps them apart.
  defp library_name(opened, module_id) do
    base =
      Memory.name_of(opened.setup.model_name_or_path) ||
        sanitise(opened.setup.logging.run_name) || sanitise(opened.name) ||
        "monty-memory"

    if length(opened.setup.learning_modules) > 1, do: base <> "-" <> module_id, else: base
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
