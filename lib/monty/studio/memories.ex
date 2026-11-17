defmodule Monty.Studio.Memories do
  @moduledoc """
  What the parts of a training run learned, put back into one memory.

  Monty's `run_parallel.py` trains one config per object and then, when the pool
  has finished, loads every part's `model.pt` and merges them
  (`GraphMatchingModel.load_state_dict_from_parallel`): per module, each part's
  graphs are loaded over what came before, so a graph two parts both trained keeps
  the later part's, and the union is the model the sequential run would have
  built. This is that merge, over the libraries the parts wrote
  (`Monty.Studio.Learned`).

  It is not a step: a part's memory is read once, when every part has finished,
  because a memory is only whole when its last rotation has been trained. That is
  what `Monty.Studio.Jobs.Run` waits for.

  The merged memory is written under the same name and release a single training
  run writes (`Learned.name_for/1`, `Learned.release/0`), so a later
  configuration finds it exactly as it would have found one run's: a batch is a
  way of taking the clock out of training, not a second kind of model. Two places
  again — the batch's own directory (`Artifacts.dir(batch_id)`) and the libraries —
  and the batch's directory is what a reader keeps when the parts are gone.
  """

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Studio.{Artifacts, Learned, Memory}

  @doc """
  The memory each part of a training batch ended with, read off its own directory.

  One map per part, keyed by module id — the same shape `Setup.memories/1`
  answers, because that is what a run starts from. A module that wrote nothing
  (the stand-in learning module, or a part whose run died before its first
  episode) is simply absent, which is what the merge reads as "nothing to add".
  """
  @spec learned([binary()], map()) :: [%{optional(String.t()) => GraphMemory.t()}]
  def learned(run_ids, opened) do
    Enum.map(run_ids, &part_memory(&1, opened))
  end

  @doc """
  One memory per module from parts that each learned some of it.

  Monty's merge, in his order: every graph of every part is loaded over the
  memory built so far (`GraphMemory.load_state_dict/2`, which replaces a graph of
  the same id and forgets its cached rows). Disjoint graphs — which is what
  splitting training *by object* gives — cannot collide, and a graph two parts
  both trained is the later part's, which is the same rule Monty's own
  `dict.update` has and for the same reason: there is no better answer to two
  graphs of one object.

  What each part said its graphs were built from travels with them. A merged
  library that kept the graphs and dropped their names would leave a recognition
  run able to name a graph and not the object it was shown — the defect
  `docs/monty-differences.md` §2.27 fixed for one run, kept alive in the path a
  divided run takes.
  """
  @spec merge([%{optional(String.t()) => %{memory: GraphMemory.t(), targets: map()}}]) ::
          %{optional(String.t()) => %{memory: GraphMemory.t(), targets: map()}}
  def merge(parts) do
    parts
    |> Enum.flat_map(&modules_of/1)
    |> Enum.group_by(fn {module_id, _learned} -> module_id end, fn {_id, learned} -> learned end)
    |> Map.new(fn {module_id, learned} -> {module_id, over_each_other(learned)} end)
  end

  @doc """
  The memory an evaluation wave starts from: the merged library its training wave
  wrote, in the shape a run's own memory has (`Setup.memories/1`).

  The pointer is the run record's, so the memory travels with the record rather
  than with the deployment: a worker on another node reads the same library.
  """
  @spec load(map(), map()) :: %{optional(String.t()) => GraphMemory.t()}
  def load(opened, %{"name" => name, "release" => release, "dir" => dir}) do
    opened.setup.learning_modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {module, index} ->
      case Memory.load_module(name, release, index, dir) do
        {:ok, memory} -> [{module.id, memory}]
        {:error, _not_written} -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  Writes the merged memory where a later configuration looks for it.

  Answers the name it is filed under, or why it could not be written. Both
  writes have to land: a memory in the batch's directory that no config can
  find is a memory a reader has and cannot use.
  """
  @spec keep(binary(), map(), %{
          optional(String.t()) => %{memory: GraphMemory.t(), targets: map()}
        }) ::
          {:ok, String.t()} | {:error, term()}
  def keep(batch, opened, memories) do
    case indexed(opened, memories) do
      [] ->
        # Nothing to merge is not a library with no record in it: that file would
        # read as a memory and recognise nothing, and would be filed over the
        # name a previous wave wrote.
        {:error, :nothing_learned}

      holding ->
        name = Learned.name_for(opened)

        with :ok <- Memory.save_all(holding, name, Learned.release(), batch_dir(batch)),
             :ok <- Memory.save_all(holding, name, Learned.release(), Memory.libraries_dir()) do
          {:ok, name}
        end
    end
  end

  @doc "Where a batch's merged memory is written, beside the runs of the batch."
  @spec batch_dir(binary()) :: Path.t()
  def batch_dir(batch), do: Path.join(Artifacts.dir(batch), "memory")

  defp modules_of(learned) do
    for {module_id, %{memory: %GraphMemory{}} = one} <- learned, do: {module_id, one}
  end

  defp over_each_other([one]), do: one

  defp over_each_other([first | rest]) do
    Enum.reduce(rest, first, fn learned, merged ->
      %{
        memory:
          GraphMemory.load_state_dict(merged.memory, GraphMemory.state_dict(learned.memory)),
        targets: Map.merge(merged.targets, learned.targets)
      }
    end)
  end

  # The parts hold their memories per module id; a library is one file with an
  # index per module, so the module's place in the config is the index it is
  # written under — the same indexing `Learned` uses for one run's memory, and
  # the same rule about a memory that holds no graph.
  defp indexed(opened, merged) do
    memories = Map.new(merged, fn {module_id, learned} -> {module_id, learned.memory} end)

    for {index, module_id, memory} <- Learned.holding(opened, memories) do
      {index, memory, Map.get(merged, module_id, %{}) |> Map.get(:targets, %{})}
    end
  end

  defp part_memory(run_id, opened) do
    opened.setup.learning_modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {module, index} ->
      case Memory.load_with_targets(
             Learned.name_for(opened),
             Learned.release(),
             index,
             Learned.dir(run_id)
           ) do
        {:ok, %{memory: memory, targets: targets}} ->
          [{module.id, %{memory: memory, targets: targets}}]

        {:error, _not_written} ->
          []
      end
    end)
    |> Map.new()
  end
end
