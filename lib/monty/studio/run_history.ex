defmodule Monty.Studio.RunHistory do
  @moduledoc """
  Every run this application has started, in the database.

  The record is created when a run starts, not when it ends: a run that is
  interrupted, or whose page is closed, is still a thing that happened. What it
  keeps is the part that is *knowledge* — which experiment, composed from which
  config, with which inputs, what happened step by step — while the artifacts a
  run produces stay on the filesystem where Monty puts them. Deleting a record
  therefore deletes history, not a trained model, and says so before it does.
  """

  import Ecto.Query

  alias ExTbpMonty.Repo
  alias Monty.Studio.RunHistory.Run

  @doc """
  Records a run that is starting.

  `attributes` are the experiment's name and source, the number of steps, and
  what the run was given: the config text and the inputs that produced it. A
  run without inputs is still a run, so only the name and the step count are
  required.
  """
  @spec start(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start(attributes) do
    attributes =
      attributes
      |> Map.put_new(:status, "running")
      |> Map.put_new(:started_at, DateTime.utc_now())

    %Run{}
    |> Run.changeset(attributes)
    |> Repo.insert()
  end

  @doc "Appends one step to a run's log."
  @spec record_step(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_step(%Run{log: log} = run, entry) do
    run |> Run.changeset(%{log: log ++ [entry]}) |> Repo.update()
  end

  @doc """
  Closes a run with its summary.

  `status` is `"finished"` or `"failed"`; the duration is taken from the run's
  own start so a page cannot make a run look faster than it was.
  """
  @spec finish(Run.t(), map(), String.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def finish(%Run{} = run, summary, status \\ "finished") do
    finished_at = DateTime.utc_now()

    run
    |> Run.changeset(%{
      status: status,
      summary: summary,
      finished_at: finished_at,
      duration_us: duration(run.started_at, finished_at)
    })
    |> Repo.update()
  end

  @doc "Runs, newest first."
  @spec list(keyword()) :: [Run.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Runs of one experiment, newest first."
  @spec list_for(String.t(), keyword()) :: [Run.t()]
  def list_for(experiment, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Run
    |> where([run], run.experiment == ^experiment)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "One run, or `nil`."
  @spec get(binary()) :: Run.t() | nil
  def get(id), do: Repo.get(Run, id)

  @doc "Forgets a run. Its artifacts are not ours to delete."
  @spec delete(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Run{} = run), do: Repo.delete(run)

  @doc "How many runs are recorded."
  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Run, :count, :id)

  defp duration(nil, _finished_at), do: 0
  defp duration(started_at, finished_at), do: DateTime.diff(finished_at, started_at, :microsecond)
end
