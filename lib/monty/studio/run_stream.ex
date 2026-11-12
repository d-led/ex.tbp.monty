defmodule Monty.Studio.RunStream do
  @moduledoc """
  The steps of a run, published by a process of their own.

  A step is what the run reported and what the sensors saw — about 15 kB, mostly
  the observations behind the pictures. Monty's experiments keep that in their
  logger and stream it to the dashboard; the database is not in the loop while a
  run steps. This is the same arrangement, with the work a step's *presentation*
  costs taken off the step as well.

  A step hands over what it has and moves on. It does not wait for:

    * the log file, which this process appends the step's line to — a write per
      step, on the caller's time before;
    * the record's own shape, which this process builds from the report — the
      entry a row keeps and the text a log line prints are derived here, so a
      step spends nothing on either;
    * the pictures, which this process names and `RunStream.Pictures` draws and
      writes — a JPEG per sensor per step, and no longer anything a boundary's
      barrier waits behind;
    * the database, which a step does not touch at all. `studio_runs` gets the
      transcript at every episode boundary and once when the run settles.

  What a step does pay is one cast and one insert into the table a page reads the
  run out of: microseconds, and no syscall. The record a run keeps in its own
  process is the counters, not the transcript: appending a step to a list copies
  the whole list, so a run of forty thousand steps copied forty thousand lists —
  `steps_from/2` reads the steps a boundary has not written yet instead.

  A step's pictures are named here, once per sensor, and drawn there: the frame a
  page draws and the scene a replay keeps are the same two PNGs, and encoding
  them on the step as well made every step pay for four. Naming them here is what
  lets the record be complete while the drawing is still queued: the name is the
  run's own convention (`<step>/<sensor>-<depth|colour>.png`).

  Writing the transcript to Postgres per step instead is what made a step cost
  grow with the run: the `timeline` is 15 kB a step and was rewritten whole each
  time, so the bytes written over a run went as $n^2/2$ — 14 MB per step by the
  end of an 887-step run, whose last hundred steps took 5 s each against 157 ms
  for its first hundred.

  Steps are numbered per run, in the order they were taken, because a step counts
  from zero again in every episode. That number is what `steps_from/2` pages by,
  and it is what a replay reads.

  A run's steps leave memory when the run's record has them: `clear/1` is called
  by whoever settled the run. The supervisor that owns this table starts again
  with nothing after a restart — a run whose node died with its steps in memory
  is a run whose row says how far it got.
  """

  use GenServer

  require Logger

  alias Monty.Studio.{Artifacts, RunLog}
  alias Monty.Studio.RunStream.Pictures

  @table __MODULE__

  # The default was five seconds, and a run whose four parts were all finishing
  # an episode at once made one of them give up: the boundary write turned the
  # timeout into a failed run. Reading a run's steps out of the table is a
  # bounded amount of work that a busy node makes slow, not impossible, so the
  # wait is generous and the failure is no longer how a run ends.
  @timeout 60_000

  @doc "Starts the table. One for the node, owned by this process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Hands one step over: what it reported, what the modules believed, and what the
  sensors saw.

  The report is a map with `:info` (the coordinator's report of the step), `:at`
  (the moment it was taken), `:episode`, `:beliefs`, `:observations`,
  `:sensor_ids` and `:centre`. Everything a page or a row needs is derived from
  those: the entry, its line, its pictures and its scene.

  `cast`, deliberately: a step that waited for this process would be a step
  waiting for a file write and a JPEG, and the point of the arrangement is that
  it does not.

  `:announce` is the run whose page is watching, when it is not the stream the
  steps are kept in. A parallel run's parts each keep their own stream — they are
  the steps of one part, which is what that part's card draws — and all of them
  announce to the one run the page opened, because a page watching a run wants
  every part's step (Monty's dashboard draws a section per publisher for the same
  reason).
  """
  @spec publish(binary(), map(), keyword()) :: :ok
  def publish(stream_id, report, options \\ []) do
    GenServer.cast(__MODULE__, {:publish, stream_id, report, Keyword.get(options, :announce)})
  end

  @doc """
  A run's steps in the order it took them, as the pair a record keeps.

  Empty when the run has left nothing in memory: a run that has settled, or one
  whose steps were taken by another node.
  """
  @spec steps(binary()) :: {[map()], [map()]}
  def steps(run_id), do: steps_from(run_id, -1)

  @doc """
  The steps of `run_id` taken after the first `from`, as the pair a record keeps.

  This is what a boundary writes: `RunHistory` says how many steps the row
  already has, and the rest is what is left here. Asking for the whole run to
  throw most of it away is the copy this exists to avoid. A negative `from` is
  the whole run — no run has a step below nought.

  A boundary needs two things of this process, and they are not the transcript:
  that every step it handed over has landed, and then its own copy of the steps.
  So it asks for the first with a `:barrier` (a message carrying nothing, answered
  after the casts that came before it, because one process sends its messages in
  order) and reads the table for the second. Asking this process for the steps
  made it build and hand over a run's whole transcript — 2 305 ms of 74 MB for a
  run of 42 401 steps — while every page waited behind it.
  """
  @spec steps_from(binary(), integer()) :: {[map()], [map()]}
  def steps_from(run_id, from) do
    :ok = GenServer.call(__MODULE__, :barrier, @timeout)
    read_from(run_id, from)
  end

  @doc """
  The steps of `run_id` taken after the first `from`, read from the table here.

  What `steps_from/2` reads once the order is settled, and what a page can read
  without waiting for this process at all: a page that asked it for steps waited
  behind every step of every run the node was writing — pictures, log lines and
  all — and five seconds of that is the page dying with a `GenServer.call`
  timeout while the run it watched stepped perfectly well.

  A step a page is told about is a step the table already holds, because the
  announcement follows the insert. What a read can miss is a step not yet
  announced, and the next announcement brings it.
  """
  @spec read_from(binary(), integer()) :: {[map()], [map()]}
  def read_from(run_id, from) do
    cond do
      not table?(@table) -> {[], []}
      # Everything: one traversal of the run's keys. Seeking each step would pay
      # a lookup a row and measured three and a half times slower (57 ms against
      # 16 ms for 42 400 steps).
      from < 0 -> between(run_id, -1)
      # The tail: the steps after this one are found by seeking, because a
      # partly bound key cannot be seeked through by `:ets.select` — reading the
      # ten steps after the forty-second thousand cost 56 ms of it instead of
      # nothing.
      true -> collect(run_id, {run_id, from}, [], [])
    end
  end

  @doc """
  How many steps of `run_id` are held here.

  A `call`, and an instant one — the count is this process's own — because a
  caller that has just handed a step over expects to hear about it (`Parts`
  reads a part's steps as soon as its cards see that it has any). What must not
  be a call is the transcript: see `steps_from/2`.
  """
  @spec count(binary()) :: non_neg_integer()
  def count(run_id), do: GenServer.call(__MODULE__, {:count, run_id}, @timeout)

  # A run's steps are `{run_id, position}` keys over dense positions, so the next
  # one is a seek and not a scan.
  defp collect(run_id, key, entries, moments) do
    case :ets.next(@table, key) do
      {^run_id, _position} = next ->
        [{_key, entry, moment}] = :ets.lookup(@table, next)
        collect(run_id, next, [entry | entries], [moment | moments])

      _end_of_the_run ->
        {Enum.reverse(entries), Enum.reverse(moments)}
    end
  end

  # Every step of one run, in one pass. The guard is what keeps the traversal on
  # this run: a partly bound key stops at the next run's first key, so the guard
  # is how the empty tail is recognised — the same read, with nothing to return.
  defp between(run_id, from) do
    @table
    |> :ets.select([
      {{{run_id, :"$1"}, :"$2", :"$3"}, [{:>, :"$1", from}], [{{:"$2", :"$3"}}]}
    ])
    |> Enum.unzip()
  end

  defp table?(name), do: :ets.whereis(name) != :undefined

  @doc """
  Forgets a run's steps.

  Called once the run's record holds them: the memory is the live view of a run
  that is still running, not a second copy of what the database has.

  A `call`, unlike `publish/2`: it runs once per run, and it has to answer after
  the steps already handed over have landed — a step cast before it and processed
  after it would put back what was just forgotten.
  """
  @spec clear(binary()) :: :ok
  def clear(run_id), do: GenServer.call(__MODULE__, {:clear, run_id}, @timeout)

  @impl true
  def init(_opts) do
    # `:public` because the writer is the run's own worker process and the
    # readers are pages, neither of which is this one.
    :ets.new(@table, [
      :named_table,
      :ordered_set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{held: %{}}}
  end

  @impl true
  def handle_cast({:publish, stream_id, report, announce}, state) do
    step = drawn(report)

    # The record keeps where a picture is, not what it is: a step's PNGs were ten
    # kilobytes of the row, and a run of twenty thousand steps does not fit in a
    # jsonb value. The page keeps drawing from the bytes it was handed.
    # The pictures are written under the directory a browser can fetch from: a
    # part's steps live in a stream of their own, but there is no run row behind a
    # stream id, and the frames route answers only for a run that exists. So a
    # part's pictures go in the run the page opened, in a folder that says which
    # part took them — every part numbers its steps from nought.
    pictures_in = announce || stream_id
    position = Map.get(state.held, stream_id, 0)
    frame = frame_key(Map.get(step, :part), position)

    # A picture's name is this run's own convention, so the record keeps it
    # before the bytes exist: `Pictures` draws and writes them, and a barrier —
    # which only waits for what this process has been handed — stops waiting
    # behind the encoding of every step still in its queue.
    moment =
      RunLog.moment(step.number, step.observations, fn sensor_id, kind ->
        Artifacts.frame_url(pictures_in, Artifacts.frame_name(frame, sensor_id, kind))
      end)

    :ets.insert(@table, {{stream_id, position}, step.entry, moment})

    # A step's line is built from its own entry here, so it is always there: the
    # file and the page are told the same words.
    say(stream_id, step.line)
    Pictures.drawn(step, pictures_in, frame)

    {:noreply, %{state | held: Map.put(state.held, stream_id, position + 1)}}
  end

  @impl true
  def handle_call({:count, run_id}, _from, state),
    do: {:reply, Map.get(state.held, run_id, 0), state}

  # What a writer asks for before it reads its own steps: that everything handed
  # over before this message is in the table. It carries nothing and answers at
  # once, where the same call used to carry a run's whole transcript.
  def handle_call(:barrier, _from, state), do: {:reply, :ok, state}

  def handle_call({:clear, run_id}, _from, state) do
    :ets.match_delete(@table, {{run_id, :_}, :_, :_})
    {:reply, :ok, %{state | held: Map.delete(state.held, run_id)}}
  end

  # Where a step's pictures are kept inside its run's directory: the step's place
  # in the run for a run of the whole experiment, the part and that place for a
  # run of several parts.
  #
  # The step's *own* number cannot name the folder: every episode of a run numbers
  # its steps from nought, so `frames/4` was every episode's fourth step at once
  # and each one wrote over the one before. A replay of a hundred and forty
  # episodes then showed a single object — the last episode's — at all 5110 steps.
  defp frame_key(nil, position), do: Integer.to_string(position)
  defp frame_key(part, position), do: "part-#{part}-#{position}"

  # What a report becomes once the record's shape and the log's text are known.
  #
  # A step that wrote its own entry and its own line spent about 600 us a step on
  # the two, and carried the beliefs twice — as the structs a page draws and as
  # the string-keyed copy a row keeps — because both travelled. What is derived
  # here travels once.
  defp drawn(%{info: info, at: at, episode: episode, beliefs: beliefs} = report) do
    entry =
      RunLog.entry(info, beliefs,
        episode: episode,
        at: at,
        part: Map.get(report, :part)
      )

    report
    |> Map.drop([:info, :at])
    |> Map.merge(%{entry: entry, line: RunLog.line(entry), number: info.step})
  end

  # The log's line, appended here: a step the page has heard of is a step the
  # file has too, because the announcement is cast after this write.
  defp say(run_id, line) do
    case Artifacts.append(run_id, line) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("studio run #{run_id}: cannot write log: #{inspect(reason)}")
    end
  end
end
