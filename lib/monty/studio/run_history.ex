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

  @doc """
  Appends one step to a run: what the modules reported and what they saw.

  Both arrays are written in one update, so a step is either in the record or
  not — a log that says step 4 happened while the timeline is still at 3 would
  be a replay that disagrees with itself.
  """
  @spec record_step(Run.t(), map(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_step(%Run{log: log, timeline: timeline} = run, entry, moment) do
    run
    |> Run.changeset(%{log: log ++ [entry], timeline: timeline ++ [moment]})
    |> Repo.update()
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

  @per_page 25

  @doc """
  One page of runs, narrowed by state and by text.

  `state` is a run's own status (`"running"`, `"finished"`, `"stopped"`,
  `"failed"`), or `"all"` for every one. `text` filters on the experiment's name,
  and **every word of it must match** — two words narrow the list instead of
  widening it, which is what a person typing a second word means.

  Answers the page, the total it is a page of, and how many pages that makes, so
  a view can draw its pager without asking again.
  """
  @spec search(keyword()) :: %{
          runs: [Run.t()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          pages: pos_integer()
        }
  def search(options \\ []) do
    state = Keyword.get(options, :state, "all")
    text = Keyword.get(options, :text, "")
    page = options |> Keyword.get(:page, 1) |> max(1)
    per_page = Keyword.get(options, :per_page, @per_page)

    narrowed = Run |> by_state(state) |> by_text(text)
    total = Repo.aggregate(narrowed, :count, :id)

    runs =
      narrowed
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{runs: runs, total: total, page: page, per_page: per_page, pages: pages(total, per_page)}
  end

  defp pages(0, _per_page), do: 1
  defp pages(total, per_page), do: div(total + per_page - 1, per_page)

  @doc "How many runs there are in each state — what the filter pills show."
  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    Run
    |> group_by([run], run.status)
    |> select([run], {run.status, count(run.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp by_state(query, state) when state in ~w(running finished stopped failed),
    do: where(query, [run], run.status == ^state)

  defp by_state(query, _every_state), do: query

  # Every word is its own condition, so the conditions narrow each other. What a
  # word may not do is act as a wildcard: `%` and `_` are characters a person
  # typed, not patterns.
  defp by_text(query, text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(query, fn word, narrowed ->
      where(narrowed, [run], fragment("? ILIKE ?", run.experiment, ^"%#{escape(word)}%"))
    end)
  end

  defp escape(word), do: Regex.replace(~r/([%_\\])/, word, "\\\\\\1")

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

  @doc """
  One run, or `nil`.

  An id that is not an id at all — a URL that has been typed wrong, an id from
  somebody else's database — is `nil`, the same as one that has been forgotten.
  Both mean "there is no such run", and neither is worth an error page.
  """
  @spec get(binary()) :: Run.t() | nil
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Run, uuid)
      :error -> nil
    end
  end

  @doc """
  Forgets every run the filter matches, and answers how many it forgot.

  The filter is the same one the list uses, so "delete all failed runs" is a
  statement about the list a person is looking at, not about the page of it they
  can see.
  """
  @spec delete_matching(keyword()) :: non_neg_integer()
  def delete_matching(options) do
    state = Keyword.get(options, :state, "all")
    text = Keyword.get(options, :text, "")

    Run
    |> by_state(state)
    |> by_text(text)
    |> select([run], run.id)
    |> Repo.all()
    |> delete_ids()
  end

  @doc "Forgets the runs with these ids, and answers how many it forgot."
  @spec delete_ids([binary()]) :: non_neg_integer()
  def delete_ids(ids) do
    ids
    |> Enum.map(&get/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.count(fn run -> match?({:ok, _deleted}, delete(run)) end)
  end

  @doc "Forgets a run, and the files it wrote. Monty's artifacts are not ours to delete."
  @spec delete(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Run{} = run) do
    deleted = Repo.delete(run)
    Monty.Studio.Artifacts.forget(run.id)
    deleted
  end

  @doc "How many runs are recorded."
  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Run, :count, :id)

  @doc """
  Remembers where this run's log file is.

  The path is stored rather than derived so a run keeps pointing at its own
  file even if the artifacts root is moved later.
  """
  @spec attach_log(Run.t(), Path.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def attach_log(%Run{} = run, path) do
    run |> Run.changeset(%{log_path: path}) |> Repo.update()
  end

  @doc """
  The run of an experiment that is still going, if there is one.

  With an `episode`, only that episode's run: an experiment can have several
  going at once, one per episode, and a page that joined the wrong one would be
  watching somebody else's object.
  """
  @spec running_for(String.t(), non_neg_integer() | nil) :: Run.t() | nil
  def running_for(experiment, episode \\ nil) do
    Run
    |> where([run], run.experiment == ^experiment and run.status == "running")
    |> then(fn query ->
      if episode, do: where(query, [run], run.episode == ^episode), else: query
    end)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every run still marked `running`, oldest first.

  A mark, not a fact: what closes a record is the job that executes it, and a
  record can outlive that job. `Monty.Studio.Jobs.Reaper` is what separates the
  two.
  """
  @spec running() :: [Run.t()]
  def running do
    Run
    |> where([run], run.status == "running")
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  defp duration(nil, _finished_at), do: 0
  defp duration(started_at, finished_at), do: DateTime.diff(finished_at, started_at, :microsecond)
end
