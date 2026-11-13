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
  alias Monty.Studio.Claim
  alias Monty.Studio.RunHistory.Part
  alias Monty.Studio.RunHistory.Run

  # One topic for every run of the application: a page that lists runs
  # subscribes once and gets the record itself, so it never has to guess
  # from a query what changed.
  @topic "studio_runs"

  # Every field but the pictures, for `head/1`. Taken from the schema so a field
  # added later is read by default rather than silently left behind. The log is
  # one of them, read as text and decoded here — see `pictures_less/1`.
  @without_log Run.__schema__(:fields) -- [:timeline, :log]

  # What a table draws. Neither the pictures nor the transcript: a row of a list
  # says which run it is, how it ended and what it cost, and 50 of them carrying
  # a log each is 50 transcripts nobody reads to render one page.
  @table_fields @without_log

  @doc """
  Records a run that is being asked for.

  `attributes` are the experiment's name and source, the number of steps, and
  what the run was given: the config text and the inputs that produced it. A
  run without inputs is still a run, so only the name and the step count are
  required.

  Nothing is stamped as started here. Asking for a run is not running it — the
  job may wait a minute for a slot, or never be picked up at all — so the row
  records *when it was asked for* (its own `inserted_at`, which is also the
  moment a queued run's wait is measured from) and `started_at` stays empty
  until a worker has the run in hand (`mark_running/1`). A start stamped at the
  asking made every run's duration include the wait in the queue: measured in
  the dev database, it began 13–26 ms before the row it was written in.
  """
  @spec start(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start(attributes) do
    attributes =
      attributes
      # Asked for is not running: the job may wait a minute for a slot, or never
      # be picked up at all. `mark_running/1` is the worker's word that it began.
      |> Map.put_new(:status, "queued")
      # Which node has it, which while it is queued is the node that asked. The
      # worker overwrites it with its own name when it claims the job, because with
      # one runs table for a cluster those are not always the same node. The value
      # is the one that decided this node's folder (`Monty.Paths.data_dir_name/0`),
      # `nil` on a node that runs alone, so the row and the directory cannot
      # disagree; a page shows the node's own name — `node1@10.0.0.7` — by asking
      # the cluster which node that is (`ExTbpMonty.Node.address/1`).
      |> Map.put_new(:node, Monty.Paths.data_dir_name())
      # Where it was asked for, which a claim does not change: the run may be
      # performed by another node, and a reader who found it there is owed the
      # name of the node it started from.
      |> Map.put_new(:started_on, Monty.Paths.data_dir_name())

    %Run{}
    |> Run.changeset(attributes)
    |> Repo.insert()
    |> tap(fn
      {:ok, run} -> broadcast({:recorded, run})
      _refused -> :ok
    end)
  end

  @doc """
  Appends one step to the record this process holds, writing nothing.

  The log is the run's transcript and the row is its checkpoint. Writing the
  whole transcript per step made a step cost grow with the run: measured on a
  300-step run, one step took 0.6–1.4 s against 2–6 ms for a single row, because
  every step re-encoded and re-sent the 3.3 MB timeline it had already sent. A
  run that steps thousands of times appends here and calls `checkpoint/1`, which
  writes only the steps the row does not have yet.
  """
  @spec append_step(Run.t(), map(), map()) :: Run.t()
  def append_step(%Run{log: log, timeline: timeline} = run, entry, moment) do
    %{run | log: log ++ [entry], timeline: timeline ++ [moment]}
  end

  @doc """
  Writes the steps appended since the last checkpoint, and only those.

  Both arrays are written together, so a step is either in the record or not — a
  log that says step 4 happened while the timeline is still at 3 would be a
  replay that disagrees with itself.

  The steps the row already has are left alone, which is what keeps a step's
  cost from growing with the run. Writing the whole transcript instead was
  measured at **14 MB rewritten per step at the end of an 887-step run** — a
  timeline of 15 kB a step, cumulative, so the bytes written over a run go as
  $n^2/2$ and the last hundred steps of that run took 5 s each against 157 ms
  for the first hundred. `docs/speed.md` has the table. What a step costs now is
  the steps since the last checkpoint, which on this path is one.

  On Postgres the two columns are appended to in the statement that writes them
  (`jsonb` concatenation), so the row is never re-encoded whole. On SQLite,
  whose JSON column this application also supports, the transcript is still
  written whole: that path is the desktop's and the statement for it is not
  written yet, so it is named here rather than pretended to be done.

  The two counts a list draws are written by the same statement, from the same
  log, so a row cannot say "three steps" about a transcript that holds two:
  `steps_done` is how many entries there are and `episodes_done` how many
  distinct episodes they name — the definitions `steps_run/1` and `episodes_run/1`
  read off a row.
  """
  @spec checkpoint(Run.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def checkpoint(%Run{log: log, timeline: timeline, steps_done: written} = run, opts \\ []) do
    # `steps_done` is the row's own count, written by this function and by
    # nothing else; a record that holds less than it claims has been replaced
    # rather than appended to, and is rewritten whole from its first step.
    written = min(written || 0, length(log))
    write(run, Enum.drop(log, written), Enum.drop(timeline || [], written), opts)
  end

  @doc """
  Writes steps the caller holds elsewhere, from the first the row does not have.

  A run's transcript lives in `Monty.Studio.RunStream` while it steps: the record
  in the run's own process is the counters, because appending a step to a list
  copies the list, and a run of forty thousand steps copied forty thousand lists.
  A boundary asks the stream for what the row has not written yet and hands it
  here.
  """
  @spec checkpoint_steps(Run.t(), [map()], [map()], keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def checkpoint_steps(%Run{} = run, new_log, new_timeline, opts \\ []),
    do: write(run, new_log, new_timeline, opts)

  @doc """
  Writes a run's whole transcript and its pictures, once, as it settles.

  The one write that carries the `timeline` — the pictures of every step — which
  a boundary deliberately leaves alone: `||` over two `jsonb` arrays is one
  statement, but Postgres still writes the whole value it concatenates. Measured
  on a 24 329-step row, appending an *empty* array took **14.7 s**; a boundary
  appending its episode's pictures therefore rewrote the row as it stood, and the
  140 of them a run of `base_10simobj_surf_agent` makes cost it about 1 000 s of
  its 1:42 h. `store/3` is that write, once, and `checkpoint/2` takes
  `timeline: :skip`.
  """
  @spec store(Run.t(), [map()], [map()]) :: {:ok, Run.t()} | {:error, term()}
  def store(%Run{} = run, log, timeline) do
    rewrite(%{
      run
      | log: log,
        timeline: timeline,
        steps_done: length(log),
        episodes_done: episodes_in(log)
    })
  end

  defp write(%Run{} = run, [], [], _opts), do: {:ok, run}

  defp write(%Run{} = run, new_log, new_timeline, opts) do
    stepped = %{
      run
      | steps_done: (run.steps_done || 0) + length(new_log),
        episodes_done: episodes_done(run.episodes_done, new_log)
    }

    if appendable?(opts) do
      append_steps(run, new_log, new_timeline, stepped, opts)
    else
      # An adapter with no append writes the record whole, so it needs the steps
      # the row already has as well as the batch — and those are in the run's
      # stream while it steps, because the record in the run's own process is the
      # counters (see `checkpoint_steps/4`).
      {log, timeline} = whole_transcript(run, new_log, new_timeline)

      rewrite(
        %{
          stepped
          | log: log,
            timeline: timeline,
            steps_done: length(log),
            episodes_done: episodes_in(log)
        },
        opts
      )
    end
  end

  # The whole transcript, from wherever it is: the stream, when a run is stepping
  # and keeps it there; the record itself otherwise — `mix monty.run` fills its own
  # record, and a run that has settled has already handed its steps over.
  defp whole_transcript(%Run{id: id} = run, new_log, new_timeline) do
    case held_steps(id) do
      {[], []} -> {(run.log || []) ++ new_log, (run.timeline || []) ++ new_timeline}
      held -> held
    end
  end

  defp held_steps(id) do
    if Process.whereis(Monty.Studio.RunStream),
      do: Monty.Studio.RunStream.steps(id),
      else: {[], []}
  end

  # The highest episode number the batch names, plus one: episodes are numbered
  # from zero and appended in order, so that is how many there have been. One
  # more step in an episode already counted leaves the number alone.
  defp episodes_done(counted, batch) do
    named = for %{"episode" => episode} <- batch, is_integer(episode), do: episode + 1
    max(counted || 0, Enum.max(named, fn -> 0 end))
  end

  # Postgres, and only Postgres: the statement appends without sending what the
  # row already holds. Any other adapter — the desktop build's SQLite is the one
  # that exists — has no `||` over a `jsonb` column, so the row is rewritten and
  # the whole transcript has to travel with the batch.
  #
  # `:append` says which of the two this write is. Nothing sets it but a test: the
  # rewrite is the path a desktop user's run takes, and asking a Postgres test
  # database to take it is the only way to have it tested at all.
  defp appendable?(opts) do
    case Keyword.fetch(opts, :append) do
      {:ok, append?} -> append?
      :error -> ExTbpMonty.Database.repo_module().__adapter__() == Ecto.Adapters.Postgres
    end
  end

  defp append_steps(%Run{id: id}, new_log, new_timeline, stepped, opts) do
    log = Jason.encode!(new_log)
    timeline = Jason.encode!(new_timeline)
    now = DateTime.utc_now()

    # A boundary leaves the pictures alone: writing them here rewrites the whole
    # `timeline`, which is the cost `store/3` exists to pay once. A skipped write
    # assigns the column to itself, which Postgres answers without touching the
    # value — the row is written, the 250 MB of pictures is not.
    pictures =
      if Keyword.get(opts, :timeline, :write) == :skip do
        dynamic([run], run.timeline)
      else
        dynamic(
          [run],
          fragment(
            "coalesce(?, '[]'::jsonb) || ?::jsonb",
            run.timeline,
            type(^timeline, :string)
          )
        )
      end

    # Whether the run is there to append to, asked as a question rather than read
    # off `update_all`'s answer: that answer is `{count, rows}` on an adapter that
    # can return rows and a bare count on one that cannot, so a pattern for it
    # type-checks on neither without a clause the analyser calls unreachable.
    if Repo.exists?(from(run in Run, where: run.id == ^id)) do
      _ =
        from(run in Run,
          where: run.id == ^id,
          update: [
            set: [
              log:
                fragment(
                  "coalesce(?, '[]'::jsonb) || ?::jsonb",
                  run.log,
                  type(^log, :string)
                ),
              steps_done:
                fragment(
                  "coalesce(jsonb_array_length(?), 0) + coalesce(jsonb_array_length(?::jsonb), 0)",
                  run.log,
                  type(^log, :string)
                ),
              # Counted over the batch being appended, not the whole transcript:
              # expanding thousands of steps to count distinct episodes held a
              # connection for fifteen seconds, and the run waiting on it died
              # (`Jobs.Run.keep_with_state/1`). Episodes are numbered from zero
              # and arrive in order, so the highest number in this batch is how
              # many episodes there have been — one more step in an episode that
              # is already counted leaves the number alone.
              episodes_done:
                fragment(
                  """
                  greatest(
                    coalesce(?, 0),
                    coalesce(
                      (select max((step->>'episode')::int) + 1
                         from jsonb_array_elements(coalesce(?::jsonb, '[]'::jsonb))
                              as step
                        where step->>'episode' ~ '^[0-9]+$'),
                      0
                    )
                  )
                  """,
                  run.episodes_done,
                  type(^log, :string)
                ),
              timeline: ^pictures,
              updated_at: ^now
            ]
          ]
        )
        |> Repo.update_all([], timeout: Monty.Studio.Settings.get("db_write_timeout_ms"))

      {:ok, stepped}
    else
      {:error, :not_found}
    end
  end

  defp rewrite(%Run{log: log, timeline: timeline} = run, opts \\ []) do
    stepped =
      run
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:log, log)
      |> Ecto.Changeset.force_change(:steps_done, length(log))
      |> Ecto.Changeset.force_change(:episodes_done, episodes_in(log))

    # `timeline: :skip` has to reach this path too: an adapter that cannot append
    # rewrites the row, and encoding the pictures to hand them back unchanged was
    # most of what that cost. Measured on a 5 000-step row on SQLite, a boundary
    # took **230 ms** when it carried the 42 MB of pictures and **45 ms** for the
    # row alone — and a run of `base_10distinctobj_dist_agent` has 140 boundaries.
    changes =
      if Keyword.get(opts, :timeline, :write) == :skip,
        do: stepped,
        else: Ecto.Changeset.force_change(stepped, :timeline, timeline)

    Repo.update(changes)
  end

  @doc "How many distinct episodes a log names, counting the steps that named none as one."
  @spec episodes_in([map()]) :: non_neg_integer()
  def episodes_in(log), do: log |> Enum.map(& &1["episode"]) |> Enum.uniq() |> length()

  @doc """
  Makes a run's record hold the steps held in memory for it, and forgets them.

  The transcript of a run that is still stepping lives in
  `Monty.Studio.RunStream`, not in the row: the row is written at an episode
  boundary. A worker that is killed — a page's "End now", a node going away, a
  process that died — cannot write its own record, so whoever closes the run
  writes what memory still has first, or the steps are lost with the process
  that took them.

  Written whole rather than appended to: memory holds the run from its first
  step, and the row may already hold a prefix of it.
  """
  @spec keep_streamed(Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def keep_streamed(%Run{id: id} = run) do
    case Monty.Studio.RunStream.steps(id) do
      {[], []} ->
        {:ok, run}

      {log, timeline} ->
        with {:ok, saved} <- rewrite(%{run | log: log, timeline: timeline}) do
          :ok = Monty.Studio.RunStream.clear(id)
          {:ok, saved}
        end
    end
  end

  @doc """
  Appends one step and writes it, for a run whose page is watching every step.
  """
  @spec record_step(Run.t(), map(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_step(run, entry, moment) do
    run
    |> append_step(entry, moment)
    |> checkpoint()
  end

  @doc """
  Says the run is still being stepped, without writing its log.

  Between checkpoints a working run's row is silent, and silence is also what a
  run whose process died looks like; the Reaper must not confuse the two. This
  is the smallest write that answers "is anybody working on it".
  """
  @spec alive(Run.t()) :: :ok
  def alive(%Run{id: id}) do
    Run
    |> where([run], run.id == ^id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])

    :ok
  end

  # An episode is minutes of stepping between two writes - a record is written at
  # its boundaries - and the Reaper judges a run by its silence, which it allows
  # a minute of. A beat every ten seconds keeps a working run six times inside
  # that, whatever the length of an episode.
  @heartbeat_seconds 10

  @doc """
  Says the run is alive, at most once every ten seconds.

  This is `alive/1` with a clock, for the two loops that step a run — the queue's
  worker and `mix monty.run` — so that neither has to know how often a run has to
  speak to keep looking alive.

  The beat is the caller's own: the monotonic second this run last said something,
  or `nil` for a caller that has not said anything yet, which is what a run that
  has just started is. It comes back as the beat to carry to the next step. A run
  with no record (`nil`) has nothing to say, and the beat it is given is the one
  it gets back.
  """
  @spec heartbeat(Run.t() | nil, integer() | nil) :: integer() | nil
  def heartbeat(nil, beat), do: beat

  def heartbeat(%Run{} = run, beat) do
    now = System.monotonic_time(:second)

    if is_nil(beat) or now - beat >= @heartbeat_seconds do
      Monty.Studio.RunWriter.alive(run)
      now
    else
      beat
    end
  end

  @doc """
  Says a run has begun, because a worker claimed it and is opening its world.

  A record is written when somebody asks for a run, and asking is not running:
  the job may wait for a slot, or never be picked up at all. This is the worker's
  own word, and the only thing on a record that may say `running`.

  It is also where `node` becomes the **node that has the run**. A row is recorded
  by the node that asked and performed by the node that claimed the job, and with
  one runs table for a cluster those are not always the same node — so the name is
  written here, from the same setting, once the answer is known. The run's live
  steps, its worker and (in a release) its files are that node's, which is why the
  column means the node a reader has to open rather than the one that asked.
  """
  @spec mark_running(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(%Run{status: "running"} = run), do: {:ok, run}

  # No announcement of its own: the worker says `{:started, steps}` on the run's
  # topic, which is what a page draws from, and every page reads the record again
  # on its tick.
  #
  # The claim is also the run's start, for the reason `start/1` is not: the clock
  # that belongs on the record is the one that began the work. Claiming twice is
  # not a second start, and the first clause above therefore keeps the first
  # instant.
  def mark_running(%Run{} = run) do
    run
    |> Ecto.Changeset.change(
      status: "running",
      node: Monty.Paths.data_dir_name(),
      started_at: DateTime.utc_now()
    )
    |> Repo.update()
  end

  @doc """
  Whether a run has not settled: asked for, and not yet closed.

  A run that is `queued` is as much in flight as one being stepped — it is a
  record with a job behind it and no ending — and every question of the form
  "may this be deleted", "may this be stopped", "is this history" is asked of
  this, not of `running` alone.
  """
  @spec in_flight?(Run.t()) :: boolean()
  def in_flight?(%Run{status: status}), do: status in ["queued", "running"]

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
    |> tap(fn
      {:ok, settled} -> broadcast({:settled, settled})
      _refused -> :ok
    end)
  end

  @doc """
  The topic a page listens to for runs it is showing.

  One topic for every run of the application, and the message carries the run
  itself: a page filters by experiment, and the row it draws is the row the
  database wrote — no second read, no page that shows a run it invented. The
  reference for the shape is `ConfluencePhxMirror`'s log and reconcile topics.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, @topic)

  # A page is told what a page of runs reads: the row, not its pictures. Every
  # subscriber takes its own copy, and a settled run of 4 789 steps carries
  # 53 MB of `timeline` that no table row looks at.
  defp broadcast(message) do
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, @topic, payload(message))
  end

  defp payload({tag, %Run{} = run}) when tag in [:recorded, :settled],
    do: {tag, %{run | timeline: []}}

  defp payload(message), do: message

  @doc "Runs, newest first."
  @spec list(keyword()) :: [Run.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> rows()
  end

  @per_page 25

  @doc """
  One page of runs, narrowed by state, by text and — when asked — by node.

  `state` is a run's own status (`"running"`, `"finished"`, `"stopped"`,
  `"failed"`), or `"all"` for every one. `text` filters on the experiment's name,
  and **every word of it must match** — two words narrow the list instead of
  widening it, which is what a person typing a second word means. `node` keeps
  only the runs one node owns, which with a file per node is every run in the
  table and with one table for the whole cluster is not.

  Answers the page, the total it is a page of, and how many pages that makes, so
  a view can draw its pager without asking again. A run on the page is a row:
  neither its pictures nor its transcript, and how many steps it has taken is
  the `steps_done` column rather than a count of a log nothing here reads.
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
    node = Keyword.get(options, :node)
    page = options |> Keyword.get(:page, 1) |> max(1)
    per_page = Keyword.get(options, :per_page, @per_page)

    narrowed = Run |> by_state(state) |> by_text(text) |> by_node(node)
    total = Repo.aggregate(narrowed, :count, :id)

    runs =
      narrowed
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> rows()

    %{runs: runs, total: total, page: page, per_page: per_page, pages: pages(total, per_page)}
  end

  # A list of runs is a list of *rows*: every column but the pictures and the
  # log. One record's `timeline` is 11 kB a step — 53 MB for a run of 4 789
  # steps — and a page of twenty-five of them is what made `/runs` wait out the
  # 15 s a connection may be checked out for. `head/1` reads the same columns as
  # a page that draws one run needs (the log, not the pictures); a page that
  # wants a run's pictures asks for one step at a time (`sensors_at/2`).
  defp rows(query) do
    query
    |> select([run], map(run, @table_fields))
    |> Repo.all()
    |> Enum.map(&struct(Run, &1))
  end

  # The row a page draws from: its log, without the pictures.
  #
  # The log is asked for as text and decoded here. Handed over as a column it is
  # the driver's document — seventy-one megabytes of it for a run of 42 401
  # steps, turned into terms a value at a time by the adapter's own decoder
  # before Ecto sees any of it. As text it is one binary, decoded once by `JSON`:
  # 2 871 ms against 5 593 ms for that run, and the same document either way.
  # `CAST(... AS text)` is how both adapters spell it — Postgres renders `jsonb`
  # as its own text, and SQLite's column already is text, where the cast is a
  # no-op. Verified on both: the desktop build's repo is started on a file, given
  # a run, and `head/1` reads its steps, their evidence and their hypotheses back.
  defp pictures_less(query) do
    query
    |> select([run], {map(run, @without_log), fragment("CAST(? AS text)", run.log)})
    |> Repo.all()
    |> Enum.map(fn {fields, log} -> struct(Run, Map.put(fields, :log, logged(log))) end)
  end

  defp logged(nil), do: []
  defp logged(text), do: JSON.decode!(text)

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

  # "Running" is what a reader means by a run that is not over: one waiting its
  # turn is not finished, failed or stopped, and a list that hid it would hide
  # the run somebody just asked for.
  defp by_state(query, "running"),
    do: where(query, [run], run.status in ["queued", "running"])

  defp by_state(query, state) when state in ~w(queued finished stopped failed),
    do: where(query, [run], run.status == ^state)

  defp by_state(query, _every_state), do: query

  # A row recorded before the column existed has no node, and there is one node it
  # can belong to: the one it is in the table of.
  defp by_node(query, nil), do: query
  defp by_node(query, node), do: where(query, [run], is_nil(run.node) or run.node == ^node)

  # Every word is its own condition, so the conditions narrow each other. What a
  # word may not do is act as a wildcard: `%` and `_` are characters a person
  # typed, not patterns. `lower` on both sides rather than `ILIKE`, which SQLite
  # does not have.
  defp by_text(query, text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(query, fn word, narrowed ->
      where(
        narrowed,
        [run],
        fragment("lower(?) LIKE lower(?)", run.experiment, ^"%#{escape(word)}%")
      )
    end)
  end

  defp escape(word), do: Regex.replace(~r/([%_\\])/, word, "\\\\\\1")

  # What a page asks about a run between its steps. Every field here is a scalar
  # or a small map: a poll costs a row, not a transcript.
  @progress_fields [
    :id,
    :experiment,
    :status,
    :steps,
    :steps_done,
    :episodes_done,
    :episode,
    :source,
    :seed,
    :summary,
    :log_path,
    :started_at,
    :finished_at,
    :inserted_at,
    :duration_us,
    :updated_at,
    # The run's inputs carry its plan when it has parts (`Monty.Studio.Partition`),
    # which is what a page drawing one card per part reads: which parts there are,
    # their phases, their episodes and the stream each one's steps live in.
    :inputs
  ]

  @doc "Runs of one experiment, newest first."
  @spec list_for(String.t(), keyword()) :: [Run.t()]
  def list_for(experiment, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Run
    |> where([run], run.experiment == ^experiment)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> rows()
  end

  @doc """
  @doc \"""
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
  One run without the pictures its sensors kept.

  A step records both halves of what a timestep is: the log, which says what the
  modules concluded, and the timeline, which holds the observations that went
  with it. Measured on a run of a thousand steps, a log row is 1.7 kB and a
  timeline entry is 11 kB — the whole record was 16 MB, and a page that read it
  again on every step spent two and a half seconds doing it.

  A page needs the log on every step and the pictures of the one step it is
  looking at, so it reads this and asks `sensors_at/2` for the frames of that
  step. The pictures are not lost, they are simply not carried around.
  """
  @spec head(binary()) :: Run.t() | nil
  def head(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Run
        |> where([run], run.id == ^uuid)
        |> pictures_less()
        |> List.first()

      :error ->
        nil
    end
  end

  @doc """
  Records the division of a run: one row per part, none of them on a node yet.

  Written when the worker decides how to divide the experiment, which is before
  any part starts — a row that says "4 parts, none of them running" is a page that
  can say how far a run of four has got, and it is the row a peer's claim will
  later fill in. `parts` are `Monty.Studio.Partition`'s, whose `index` is
  zero-based.

  Whatever a previous attempt wrote is replaced: a run performed twice is two
  divisions of the same experiment, and the second is the one that happened.
  """
  @spec plan_parts(binary(), [map()]) :: :ok
  def plan_parts(run_id, parts) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id) do
      _ = Repo.delete_all(from part in Part, where: part.run_id == ^uuid)

      rows =
        for part <- parts do
          %{
            id: Ecto.UUID.generate(),
            run_id: uuid,
            part: part.index,
            of: part.of,
            status: "queued",
            steps: 0,
            inserted_at: now(),
            updated_at: now()
          }
        end

      _ = Repo.insert_all(Part, rows)
    end

    :ok
  end

  @doc """
  The parts of a run that have already ended, by the number the division gave
  them.

  The one question a resumed run asks before it steps a wave: a part that
  finished, failed or was stopped has its steps on disk and its episodes in what
  the record adds up, so performing it again would be work done twice and a
  transcript with two copies of it.

  `parts/1` is the division itself, and it is what a run that is performed again
  re-enters instead of planning: `plan_parts/2` deletes what it replaces, which is
  right for a second *attempt* at one experiment and wrong for the same attempt
  continuing.
  """
  @spec ended_parts(binary()) :: MapSet.t(non_neg_integer())
  def ended_parts(run_id) do
    run_id
    |> parts()
    |> Enum.filter(&(&1.status in ~w(finished failed stopped)))
    |> MapSet.new(& &1.part)
  end

  @doc """
  A run's numbers as far as it has got, without closing it.

  A run of several parts adds its parts up in memory and writes the total once,
  when it ends — right for a run that ends, and wrong for one whose worker
  disappears: the attempt's numbers would be the only copy, and a run that
  continues would start counting from zero over episodes that already concluded.
  This is the map `finish/3` would store, written early, so the resume has
  something true to add to.
  """
  @spec checkpoint_summary(binary(), map()) :: :ok
  def checkpoint_summary(run_id, summary) when is_map(summary) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id) do
      _ =
        from(run in Run, where: run.id == ^uuid)
        |> Repo.update_all(set: [summary: summary, updated_at: now()])
    end

    :ok
  end

  @doc """
  The run is waiting for a worker again.

  What a run is after the worker that had it disappeared and the run was put back
  in the queue (`Monty.Studio.Jobs.Reaper.recover/0`). `queued` is the true word
  for that: the page that reads `running` draws work, and there is no work until a
  worker takes it.
  """
  @spec requeue(binary()) :: :ok
  def requeue(run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id) do
      _ =
        from(run in Run, where: run.id == ^uuid)
        |> Repo.update_all(set: [status: "queued", updated_at: now()])
    end

    :ok
  end

  @doc """
  The node that is to perform a part takes it, and the row says so before it starts.

  `node` is the spelling that decided the node's folder (`Monty.Paths.data_dir_name/0`),
  which is how a page translates it back to the name a peer dials — the same
  translation the run's own `node` column gets.

  A part is claimed, not merely announced: the answer carries the token that
  fences the writes about it (`Monty.Studio.Claim`), and a part that another node
  has — or one that has already ended — is refused rather than taken. That refusal
  is what stops two nodes performing one part of one experiment at the same time.

  A claim on a part whose previous holder went silent is granted: its lease has
  lapsed, and the part is nobody's until somebody takes it.
  """
  @spec claim_part(binary(), non_neg_integer(), String.t() | nil) ::
          {:ok, Claim.t()} | {:error, term()}
  def claim_part(run_id, part, node) do
    moment = now()

    case Ecto.UUID.cast(run_id) do
      {:ok, uuid} ->
        claim_free(uuid, part, node, Claim.new(run_id, part, node, moment), moment)

      # Not a run id, so not a part of any run: the answer a claim gets is the one
      # a part that was never planned gets.
      :error ->
        {:error, :not_planned}
    end
  end

  # The row is taken only if nobody holds it, or if the holder's lease has run
  # out: the whole of "one owner at a time" is the one `update_all/3` below.
  defp claim_free(uuid, part, node, claim, moment) do
    free =
      from(candidate in Part,
        where:
          candidate.run_id == ^uuid and candidate.part == ^part and
            candidate.status in ["queued", "running"] and
            (is_nil(candidate.claimed_until) or candidate.claimed_until < ^moment)
      )

    # `started_at` is the first instant a node had the part, not the latest: a part
    # that lapsed once and was reassigned began when its first holder took it.
    # Written as a second statement, and only for a part nothing has started yet,
    # because a column may not refer to itself in one `update_all/3`.
    case Repo.update_all(free,
           set: [
             claim: claim.token,
             claimed_until: claim.until,
             node: node,
             status: "running",
             updated_at: moment
           ]
         ) do
      {1, _one_part} ->
        from(candidate in Part,
          where:
            candidate.run_id == ^uuid and candidate.part == ^part and
              is_nil(candidate.started_at)
        )
        |> Repo.update_all(set: [started_at: moment])

        {:ok, claim}

      {0, _nothing} ->
        {:error, refusal(uuid, part)}
    end
  end

  @doc """
  The holder says it is still working, and the claim stands for another lease.

  Called as the part steps (`Monty.Studio.Jobs.Run`): a part that is alive is
  never silent for a whole lease, and a part that stopped saying so is one the
  cluster may give away.
  """
  @spec renew_claim(Claim.t()) :: :ok | {:error, :lapsed}
  def renew_claim(%Claim{} = claim) do
    moment = now()
    renewed = Claim.renew(claim, moment)

    held =
      from(candidate in Part,
        where:
          candidate.run_id == ^claim.run_id and candidate.part == ^claim.part and
            candidate.claim == ^claim.token and candidate.status == "running"
      )

    case Repo.update_all(held, set: [claimed_until: renewed.until, updated_at: moment]) do
      {1, _one_part} -> :ok
      {0, _nothing} -> {:error, :lapsed}
    end
  end

  @doc """
  The holder writes how its part ended — and only the holder can.

  `status` is `"finished"`, `"failed"` or `"stopped"`, and the steps are what the
  part managed before it did. A node whose claim lapsed, or whose part was given
  to a peer while it was unreachable, is refused here: its work is not allowed to
  overwrite the work of the node that has the part now.
  """
  @spec release_part(Claim.t(), String.t(), non_neg_integer()) :: :ok | {:error, :not_owner}
  def release_part(%Claim{} = claim, status, steps) when status in ~w(finished failed stopped) do
    moment = now()

    held =
      from(candidate in Part,
        where:
          candidate.run_id == ^claim.run_id and candidate.part == ^claim.part and
            candidate.claim == ^claim.token
      )

    # The claim goes with the ending: a part that is settled is nobody's, and a
    # holder that lost its part before this call finds no token to match.
    set = [
      status: status,
      steps: steps,
      finished_at: moment,
      claim: nil,
      claimed_until: nil,
      updated_at: moment
    ]

    case Repo.update_all(held, set: set) do
      {1, _one_part} -> :ok
      {0, _nothing} -> {:error, :not_owner}
    end
  end

  @doc """
  The holder gives the part back without a verdict about it, so another node can
  take it.

  What a part whose node died mid-wave needs: the part is not finished, not
  failed and not skipped — it is unfinished, and the run wants it performed. The
  row goes back to `queued` with the steps it had, and the claim is cleared.
  """
  @spec abandon_part(Claim.t()) :: :ok | {:error, :not_owner}
  def abandon_part(%Claim{} = claim) do
    moment = now()

    held =
      from(candidate in Part,
        where:
          candidate.run_id == ^claim.run_id and candidate.part == ^claim.part and
            candidate.claim == ^claim.token
      )

    case Repo.update_all(held,
           set: [status: "queued", claim: nil, claimed_until: nil, updated_at: moment]
         ) do
      {1, _one_part} -> :ok
      {0, _nothing} -> {:error, :not_owner}
    end
  end

  @doc """
  The parts of a run that somebody is still working on: in hand, and the holder
  has renewed its lease since it took it.

  The other half of `lapsed_parts/1`. A run of several parts is performed by the
  cluster, not by one node: a part can be in a peer's hands while this node's own
  registry knows nothing about it, so "is anybody still working on this run" cannot
  be answered from what this node has running — the claim is the answer, and the
  clock is what makes it expire.

  Which is a question a node asks before it **continues** a run
  (`Monty.Studio.Jobs.Reaper.recover/0`), not before it closes one: a run whose job
  was cancelled is one somebody stopped, and a dead worker's claim outliving its job
  by a lease is not evidence against the person who pressed Stop.
  """
  @spec claimed_parts(binary()) :: [Part.t()]
  def claimed_parts(run_id) do
    moment = now()

    run_id
    |> parts()
    |> Enum.filter(&(&1.status == "running" and not Claim.lapsed?(&1.claimed_until, moment)))
  end

  @doc """
  The parts of a run that nobody is working on any more: in hand, and the holder
  has not said a word since its lease ran out.

  These are the parts a lost node leaves behind, and the answer to "what would be
  reassigned if this run were recovered now".
  """
  @spec lapsed_parts(binary()) :: [Part.t()]
  def lapsed_parts(run_id) do
    moment = now()

    case Ecto.UUID.cast(run_id) do
      {:ok, uuid} ->
        Part
        |> where(
          [part],
          part.run_id == ^uuid and part.status == "running" and
            (is_nil(part.claimed_until) or part.claimed_until < ^moment)
        )
        |> order_by([part], asc: part.part)
        |> Repo.all()

      :error ->
        []
    end
  end

  @doc """
  Closes the division: nothing is left saying a finished run is still working.

  A part that started and never finished — a wave that failed around it, a run
  stopped between waves — becomes `failed`; one the run never got to becomes
  `skipped`. Both carry the moment, so a page can say when the run's attempt at
  that part ended.

  Called by the worker once the waves are over, whatever the outcome: the rows
  describe an attempt, and an attempt that ended must not look like one in
  progress.
  """
  @spec settle_parts(binary()) :: :ok
  def settle_parts(run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id) do
      moment = now()
      # A part that is settled is nobody's: the claims go with the status, so a
      # row of a finished run cannot look like one a node is still working on.
      nothing_held = [claim: nil, claimed_until: nil, updated_at: moment]

      _ =
        from(part in Part, where: part.run_id == ^uuid and part.status == "queued")
        |> Repo.update_all(set: [status: "skipped", finished_at: moment] ++ nothing_held)

      _ =
        from(part in Part, where: part.run_id == ^uuid and part.status == "running")
        |> Repo.update_all(set: [status: "failed", finished_at: moment] ++ nothing_held)
    end

    :ok
  end

  @doc """
  The parts of a run, in the order the division numbered them.

  Empty for a run that was not divided, which is the run of one part: there is no
  division to show.
  """
  @spec parts(binary()) :: [Part.t()]
  def parts(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, uuid} ->
        Part
        |> where([part], part.run_id == ^uuid)
        |> order_by([part], asc: part.part)
        |> Repo.all()

      :error ->
        []
    end
  end

  # Why a part could not be claimed, in the words the run logs: a part that ended
  # has an answer already, and a part somebody else holds names its holder.
  defp refusal(uuid, part) do
    row =
      Repo.one(
        from candidate in Part, where: candidate.run_id == ^uuid and candidate.part == ^part
      )

    case row do
      nil ->
        :not_planned

      %Part{status: status} when status in ~w(finished failed stopped skipped) ->
        {:settled, status}

      %Part{node: node, claimed_until: until} ->
        {:held, node, until}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc """
  What a page polls for: how the run is doing, without what it said.

  An experiment page asked `get/1` twice a second, which is the transcript *and*
  the pictures — 252 MB by the end of a 24 329-step run, per request, while the
  run was trying to step. A poll needs the state, the counters and the ending; the
  transcript is read once, when the page catches up after the run has stopped.
  """
  @spec progress(binary()) :: Run.t() | nil
  def progress(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Run
        |> where([run], run.id == ^uuid)
        |> select([run], map(run, @progress_fields))
        |> Repo.all()
        |> List.first()
        |> case do
          nil -> nil
          fields -> struct(Run, fields)
        end

      :error ->
        nil
    end
  end

  @doc """
  Whether a run with this id exists at all.

  What a controller that is about to serve one of a run's files asks — and the
  only thing it asks. A row would carry that run's transcript across the wire to
  answer a yes.
  """
  @spec exists?(binary()) :: boolean()
  def exists?(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.exists?(where(Run, [run], run.id == ^uuid))
      :error -> false
    end
  end

  @doc """
  What the sensors of one recorded position saw, or `nil` if nothing was recorded there.

  `position` counts steps the way a replay does — from zero, across episodes —
  which is the array's own index.
  """
  @spec sensors_at(binary(), non_neg_integer()) :: map() | nil
  def sensors_at(id, position) when position >= 0 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Run
        |> where([run], run.id == ^uuid)
        |> select(
          [run],
          # `->` with an integer indexes a JSON array on both databases — a
          # Postgres array is 1-based and a JSON one is 0-based, and the timeline
          # is a JSON array now that it is one document. The cast is not optional:
          # `jsonb -> int4` is the only integer overload Postgres has, and an
          # Elixir integer is bound as int8 ("operator does not exist: jsonb ->
          # bigint"). `CAST(... AS int)` is how both databases spell int4, where
          # `::` would be Postgres-only.
          fragment("? -> CAST(? AS int)", run.timeline, ^position)
        )
        |> Repo.one()
        |> case do
          nil -> nil
          entry -> entry |> json() |> Map.get("sensors", %{})
        end

      :error ->
        nil
    end
  end

  # Postgres hands the element back decoded; SQLite hands back its text.
  defp json(value) when is_binary(value), do: Jason.decode!(value)
  defp json(value), do: value

  @doc """
  Deletes every run the filter matches, and answers how many it deleted.

  The filter is the same one the list uses, so "delete all failed runs" is a
  statement about the list a person is looking at, not about the page of it they
  can see.
  """
  @spec delete_matching(keyword(), keyword()) :: non_neg_integer()
  def delete_matching(options, opts \\ []) do
    options |> ids_matching() |> delete_ids(opts)
  end

  @doc "The ids of every run a filter matches — the same filter the list takes."
  @spec ids_matching(keyword()) :: [binary()]
  def ids_matching(options) do
    state = Keyword.get(options, :state, "all")
    text = Keyword.get(options, :text, "")

    Run
    |> by_state(state)
    |> by_text(text)
    |> select([run], run.id)
    |> Repo.all()
  end

  # How many runs one statement deletes. Small enough that a page hears about a
  # long delete while it is happening, large enough that the round trips are not
  # the cost.
  @delete_chunk 50

  @doc """
  Deletes the runs with these ids, and answers how many it deleted.

  Deleted in chunks with `delete_all`, not a `get` and a `delete` a run: fetching
  each record first read every picture the row held — 156 MB for this machine's
  seventy-seven runs — only to throw it away, which is what made "delete all"
  take long enough to look like nothing was happening.

  `:on_progress` is called after each chunk with `%{deleted: n, total: total}`,
  which is what a page shows while the rest of the list is going.
  """
  @spec delete_ids([binary()], keyword()) :: non_neg_integer()
  def delete_ids(ids, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress)

    # An id that cannot be a run's is not a run, so it is not an error either:
    # the query would refuse to compare a malformed uuid at all.
    ids = Enum.filter(ids, &match?({:ok, _uuid}, Ecto.UUID.cast(&1)))
    total = length(ids)

    ids
    |> Enum.chunk_every(@delete_chunk)
    |> Enum.reduce(0, fn chunk, deleted ->
      {count, _rows} = Repo.delete_all(from(run in Run, where: run.id in ^chunk))

      # Their divisions too, for the reason `delete/1` gives: no foreign key, so
      # the statement that deletes a run deletes what belongs to it. A part row
      # left behind would be a row about a run nobody can open.
      _ = Repo.delete_all(from(part in Part, where: part.run_id in ^chunk))

      Enum.each(chunk, &Monty.Studio.Artifacts.forget/1)

      deleted = deleted + count
      if on_progress, do: on_progress.(%{deleted: deleted, total: total})
      deleted
    end)
  end

  @doc "Deletes a run, and the files it wrote. Monty's artifacts are not ours to delete."
  @spec delete(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Run{} = run) do
    # The division goes with the run. There is no foreign key to do it: the two
    # adapters this application runs on are Postgres and SQLite, and adding a
    # constraint to an existing table is a table rebuild SQLite's adapter does
    # not do — so the one place that deletes a run deletes what belongs to it.
    _ = Repo.delete_all(from(part in Part, where: part.run_id == ^run.id))
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
    |> where([run], run.experiment == ^experiment and run.status in ["queued", "running"])
    |> then(fn query ->
      if episode, do: where(query, [run], run.episode == ^episode), else: query
    end)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    # Read on every poll of a page that is not watching a run, and what the
    # callers do with it is start watching: the id, the status, where its log is
    # and how far the last episode got. The pictures are the run's heaviest
    # column and none of them is asked for.
    |> pictures_less()
    |> List.first()
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
    # A run that was asked for and never claimed is as unsettled as one being
    # stepped: the reaper is what decides it is nobody's, and it cannot decide
    # about a row it is not shown.
    |> where([run], run.status in ["queued", "running"])
    |> order_by(asc: :inserted_at)
    |> rows()
  end

  # A run writes its record while it is working — a step's results, or the
  # heartbeat a runner sends between them — so silence means one thing: nothing
  # new has happened. That is the only question worth asking here.
  #
  # Not the run's total. A run that has been going for hours is no closer to
  # being dead than one that started a minute ago, and projecting a deadline
  # from its average pace abandons a run for being slow — which is what a
  # 140-episode run is. The grace is a minute: long enough that a slow step does
  # not trip it, short enough that a person does not outlive the page.
  #
  # Death is not this either: `Monty.Studio.Jobs.Reaper` settles that by looking
  # for a process. And nothing here cancels a run. A quiet record is the page
  # saying so and the run left to finish; whoever owns the process decides.

  @doc """
  How long this run's record has been unchanged, in seconds.

  A step writes the record, so this is also how long ago the last step landed —
  the one number a page can offer when a run looks alive but says nothing.
  """
  @spec quiet_for(Run.t(), DateTime.t()) :: non_neg_integer()
  def quiet_for(%Run{updated_at: %DateTime{} = at}, now \\ DateTime.utc_now()) do
    DateTime.diff(now, at, :second)
  end

  @doc """
  How many steps the run actually took.

  The record's `steps` column is the budget an episode is allowed, not what
  happened: a run given 500 steps that recognised its object at 22 has a column
  saying 500 and a log saying 22. A page that shows the column as the run's
  length is a page that lies, so it asks this instead — and the answer is the
  count written beside the log, so a row of a list can give it without reading
  the transcript.
  """
  @spec steps_run(Run.t()) :: non_neg_integer()
  def steps_run(%Run{steps_done: steps_done}), do: steps_done

  @doc "How many of the experiment's episodes this run actually stepped."
  @spec episodes_run(Run.t()) :: non_neg_integer()
  def episodes_run(%Run{episodes_done: episodes_done}), do: episodes_done

  @doc """
  How many episodes the run was asked for — the whole experiment, unless the
  caller sliced it. `nil` for a record that does not say.
  """
  @spec episodes_asked(Run.t()) :: non_neg_integer() | nil
  def episodes_asked(%Run{inputs: %{"episodes" => count}}) when is_integer(count) and count > 0,
    do: count

  def episodes_asked(%Run{}), do: nil

  @doc """
  How the run ended, in the model's own terms, or `nil` where the state says it.

  The state badge answers "did the record close"; this answers "what did it
  conclude" — the question a run that stopped after twenty-two steps raises and
  a step count cannot settle.
  """
  @spec ending(Run.t()) :: String.t() | nil
  def ending(%Run{status: "running"}), do: nil

  def ending(%Run{status: "failed"} = run) do
    case run.summary do
      # The Reaper's words, condensed to a column: the sentence it wrote is on
      # the run's own page.
      %{"reason" => reason} when is_binary(reason) -> "abandoned"
      _failed_another_way -> "failed"
    end
  end

  def ending(%Run{status: "finished"} = run) do
    case run.summary do
      %{"steps" => 0} -> "no steps"
      %{"outcome" => outcome} when is_map(outcome) -> conclusion(outcome)
      _no_summary -> nil
    end
  end

  def ending(%Run{}), do: nil

  # What the modules concluded. `match` anywhere is a recognition, which is the
  # criterion these configs name; a run whose modules simply said no is not the
  # the same result and does not get the same word. A finished run that
  # concluded nothing ran its whole budget, which is a reason too — a blank cell
  # said nothing, and the one thing a column of endings must not do is leave a
  # reader guessing whether the run is still going.
  defp conclusion(outcome) do
    concluded = outcome |> Map.values() |> Enum.reject(&is_nil/1)

    cond do
      "match" in concluded -> "recognised"
      "no_match" in concluded -> "no match"
      "time_out" in concluded -> "timed out"
      true -> "out of steps"
    end
  end

  @doc """
  Is this run claiming to be running with nothing to show for it?

  Silence is only a fault while a run says it is going: a queued run has no steps
  yet by definition, and a finished one has nothing left to say. What is measured
  is whether anything new arrived — nothing else about the run enters into it.
  """
  @spec stalled?(Run.t(), DateTime.t()) :: boolean()
  def stalled?(run, now \\ DateTime.utc_now())

  def stalled?(%Run{status: "running"} = run, now) do
    quiet_for(run, now) > Monty.Studio.Settings.get("run_stale_after_s")
  end

  def stalled?(%Run{}, _now), do: false

  defp duration(nil, _finished_at), do: 0
  defp duration(started_at, finished_at), do: DateTime.diff(finished_at, started_at, :microsecond)
end
