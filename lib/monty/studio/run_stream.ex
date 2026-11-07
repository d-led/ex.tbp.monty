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
    * the pictures, which this process encodes — a JPEG per sensor per step;
    * the database, which a step does not touch at all. `studio_runs` gets the
      transcript at every episode boundary and once when the run settles.

  What a step does pay is one cast and one insert into the table a page reads the
  run out of: microseconds, and no syscall.

  Writing the transcript to Postgres per step instead is what made a step cost
  grow with the run: the `timeline` is 15 kB a step and was rewritten whole each
  time, so the bytes written over a run went as $n^2/2$ — 14 MB per step by the
  end of an 887-step run, whose last hundred steps took 5 s each against 157 ms
  for its first hundred.

  Steps are keyed by a monotonic integer rather than by their step number,
  because a step counts from zero again in every episode. Their order is the
  order they were taken in, which is what a replay reads.

  A run's steps leave memory when the run's record has them: `clear/1` is called
  by whoever settled the run. The supervisor that owns this table starts again
  with nothing after a restart — a run whose node died with its steps in memory
  is a run whose row says how far it got.
  """

  use GenServer

  require Logger

  alias Monty.Simulators.Synthetic.{Camera, Environment}
  alias Monty.Studio.Artifacts

  @table __MODULE__

  @doc "Starts the table. One for the node, owned by this process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Hands one step over: what it reported, what the sensors saw, and enough to
  draw it.

  The step is a map with `:entry` and `:moment` (what the record keeps),
  `:observations` and `:sensor_ids` (what the pictures are drawn from),
  `:number`, `:episode`, `:line`, `:beliefs` and `:centre` (what a page draws).

  `cast`, deliberately: a step that waited for this process would be a step
  waiting for a file write and a JPEG, and the point of the arrangement is that
  it does not.
  """
  @spec publish(binary(), map()) :: :ok
  def publish(run_id, step), do: GenServer.cast(__MODULE__, {:publish, run_id, step})

  @doc """
  A run's steps in the order it took them, as the pair a record keeps.

  Empty when the run has left nothing in memory: a run that has settled, or one
  whose steps were taken by another node.
  """
  @spec steps(binary()) :: {[map()], [map()]}
  def steps(run_id) do
    run_id
    |> taken()
    |> Enum.unzip()
  end

  @doc "How many steps of `run_id` are held here."
  @spec count(binary()) :: non_neg_integer()
  def count(run_id), do: run_id |> taken() |> length()

  @doc """
  Forgets a run's steps.

  Called once the run's record holds them: the memory is the live view of a run
  that is still running, not a second copy of what the database has.

  A `call`, unlike `publish/2`: it runs once per run, and it has to answer after
  the steps already handed over have landed — a step cast before it and processed
  after it would put back what was just forgotten.
  """
  @spec clear(binary()) :: :ok
  def clear(run_id), do: GenServer.call(__MODULE__, {:clear, run_id})

  # An `ordered_set` answers a range of one run's keys in the order they were
  # taken, which is the order a monotonic integer is inserted in.
  defp taken(run_id) do
    @table
    |> :ets.select([{{{run_id, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

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

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:publish, run_id, step}, state) do
    :ets.insert(@table, {{run_id, System.unique_integer([:monotonic])}, step.entry, step.moment})

    if step.line, do: say(run_id, step.line)

    broadcast(run_id, {:step, announcement(step, frames_of(step))})
    {:noreply, state}
  end

  @impl true
  def handle_call({:clear, run_id}, _from, state) do
    :ets.match_delete(@table, {{run_id, :_}, :_, :_})
    {:reply, :ok, state}
  end

  # What a page draws a step from: its line, the pictures, and what the learning
  # modules concluded. The observations themselves stay in `steps/1`, where a
  # replay reads them.
  defp announcement(step, frames) do
    %{
      line: step.line,
      episode: step.episode,
      step: step.number,
      frames: frames,
      beliefs: step.beliefs,
      centre: step.centre
    }
  end

  # Every sensor, every step. A queued run has no socket waiting on it, so there
  # is nothing to throttle for; the frames are not thumbnails either — they are
  # the same drawing a live page would get.
  defp frames_of(step) do
    seen = Map.get(step.observations, Environment.agent_id(), %{})

    step.sensor_ids
    |> Enum.filter(&Map.has_key?(seen, &1))
    |> Enum.map(&Camera.frame(&1, seen[&1], step.number))
    |> Enum.map(&Map.take(&1, [:sensor_id, :media_type, :data, :note]))
  end

  defp say(run_id, line) do
    case Artifacts.append(run_id, line) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("studio run #{run_id}: cannot write log: #{inspect(reason)}")
    end
  end

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      Monty.Studio.Jobs.Run.topic(run_id),
      {:studio, run_id, event}
    )
  end
end
