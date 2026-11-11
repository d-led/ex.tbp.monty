defmodule Monty.Studio.Jobs.Merge do
  @moduledoc """
  The step between a training wave and the evaluation that reads it.

  Monty's `run_parallel.py` runs the training configs, then, when the pool is
  empty, calls `post_parallel_train`: it loads each part's `model.pt`, merges them
  into one model, saves it as the experiment's memory, and only then runs the
  evaluation configs. This is that step as a job of its own.

  It waits by snoozing. A part that is still `running` is a part whose memory is
  not written yet, and a merge that read it early would be a model missing an
  object — so the job asks again in a second rather than blocking a worker of the
  queue the parts are running in.

  What it does when every part has finished is three things, in this order:

    1. reads the parts' memories and merges them (`Monty.Studio.Memories`);
    2. writes the merged memory where a later configuration looks for it;
    3. queues the evaluation wave, pointed at that memory — the one thing
       `run_parallel.py` does not do for a config that both trains and evaluates,
       and the reason a partitioned run of such a config evaluates what it just
       trained rather than the library its config names.

  A batch whose training failed is a batch that does not evaluate: the job is
  cancelled with that sentence rather than starting an evaluation on half a
  memory.
  """

  use Oban.Worker, queue: :studio, max_attempts: 1

  require Logger

  alias Monty.Studio
  alias Monty.Studio.{Failure, Learned, Memories, RunHistory, RunLog}

  @doc """
  Queues the merge of a batch, and the parts of the evaluation wave it starts.

  `eval` is the evaluation wave's plan (`Monty.Studio.Partition`) as data, so the
  job can start those parts without the page that started the batch — the page
  may be closed, and the batch is not the page's.
  """
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(args) do
    %{
      "batch" => args.batch,
      "experiment" => args.experiment,
      "steps" => args.steps,
      "parallel" => args.parallel,
      "eval" => args.eval
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch" => batch} = args}) do
    parts = train_parts(batch)

    # A part still going is a memory not written yet; a part that ended any other
    # way than `finished` is a memory missing an object, and an evaluation of it
    # would be an evaluation of half an experiment.
    running = Enum.find(parts, &(&1.status == "running"))
    broken = Enum.find(parts, &(&1.status not in ["running", "finished"]))

    cond do
      parts == [] ->
        :ok

      running != nil ->
        {:snooze, 1}

      broken != nil ->
        {:cancel, "part #{label(broken)} of the training wave ended #{broken.status}"}

      true ->
        merge(batch, args, Enum.map(parts, & &1.id))
    end
  end

  # The training parts of a batch, read off the records: a part says which phase
  # it is in what it was given, so nothing here has to guess from the order.
  defp train_parts(batch) do
    batch
    |> RunHistory.parts()
    |> Enum.filter(&(get_in(&1.inputs, ["part", "phases", "train"]) != nil))
  end

  defp label(run) do
    case get_in(run.inputs, ["part", "index"]) do
      nil -> run.id
      index -> "#{index + 1}"
    end
  end

  defp merge(batch, args, run_ids) do
    case Studio.open(args["experiment"]) do
      {:ok, opened} ->
        memories = run_ids |> Memories.learned(opened) |> Memories.merge()

        case Memories.keep(batch, opened, memories) do
          {:ok, name} ->
            Logger.info("batch #{batch}: merged #{length(run_ids)} part(s) into #{name}")
            start_evaluation(opened, batch, args, name)

          {:error, reason} ->
            {:cancel,
             Failure.explain("the merged memory could not be written", inspect(reason)).what}
        end

      {:error, reason} ->
        {:cancel, Failure.explain("the experiment could not be opened", inspect(reason)).what}
    end
  end

  # The evaluation wave starts from the memory the training wave built, which is
  # the one thing this port has to say that Monty's own parallel runner does not.
  defp start_evaluation(opened, batch, args, name) do
    memory = %{"name" => name, "release" => Learned.release(), "dir" => Memories.batch_dir(batch)}

    Enum.each(args["eval"] || [], &start_part(opened, batch, args, memory, &1))
  end

  defp start_part(opened, batch, args, memory, part) do
    attributes =
      RunLog.attributes(
        opened,
        args["steps"],
        hd(part["episodes"]),
        part["of"],
        length(part["episodes"]),
        %{
          batch: batch,
          index: part["index"],
          of: part["of"],
          phases: %{eval: part["episodes"]},
          memory: memory
        }
      )

    with {:ok, record} <- RunHistory.start(attributes),
         {:ok, _job} <- Monty.Studio.Jobs.Run.enqueue_run(record) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("batch #{batch}: evaluation part could not be queued: #{inspect(reason)}")
        :ok
    end
  end
end
