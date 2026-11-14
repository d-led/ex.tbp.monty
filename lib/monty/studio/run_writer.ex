defmodule Monty.Studio.RunWriter do
  @moduledoc """
  The one process that writes a run's steps, so the run does not wait for them.

  A step's transcript is the experiment's record, not its work: an episode
  boundary asks for the steps since the last boundary to be written, and 3.3 s a
  boundary of a run's 84 episodes was spent waiting for Postgres while the model
  sat idle (`59613a1c`). The run hands the steps over and steps on.

  One process, not a task per write, because the steps are appended: a transcript
  written in the order it was taken is the only transcript worth keeping. The
  run keeps its own count of what it has *handed over*, so it never asks twice,
  and a write that fails is logged here without the run knowing.

  The closing write is a call: a run that is finishing has nothing left to
  overlap with, and the record must be whole before the run is marked finished.
  """

  use GenServer

  require Logger

  alias Monty.Studio.RunHistory
  alias Monty.Studio.RunHistory.Run

  # The heap this process grows to is the heap of the largest thing it was handed:
  # a checkpoint carries an episode's steps, and an episode of a big run is
  # megabytes. Nothing in the runtime tells an idle process to give a heap back,
  # so it kept it for the life of the node. Measured on a live run of 12 448
  # steps: this process sat on **331 MB of collected-but-unreturned heap** with an
  # empty mailbox and 2 KB of live data, and one forced GC took the node from
  # 840 MB to 434 MB. The machine crossed its memory watermark every ten minutes,
  # and under that watermark the VM suspends processes — sockets lose their
  # heartbeat, and a reader watches the page disconnect while the run is fine.
  # Hibernating when idle is how a BEAM process returns that heap; a test sets it
  # to milliseconds so the behaviour can be asserted.
  @idle_after Application.compile_env(:ex_tbp_monty, :studio_idle_hibernate_after, 5_000)

  @typedoc "A slice of a run's transcript: the entries, and each one's moment."
  @type steps :: {[map()], [map()]}

  @doc "Writes the steps an episode boundary produced, when this process gets to it."
  @spec checkpoint(Run.t(), steps(), non_neg_integer()) :: :ok
  def checkpoint(%Run{} = run, {log, timeline}, handed) do
    GenServer.cast(__MODULE__, {:checkpoint, run, log, timeline, handed})
  end

  @doc """
  Says the run is alive, when this process gets to it.

  A heartbeat is the run telling the Reaper it is still working; the run has no
  business waiting for a row to be touched to say so, and the ten-second rhythm
  is the caller's (`RunHistory.heartbeat/2`).
  """
  @spec alive(Run.t()) :: :ok
  def alive(%Run{} = run), do: GenServer.cast(__MODULE__, {:alive, run})

  @doc """
  The closing write, and everything handed over before it.

  A call, so that the caller knows the record holds every step it took. Nothing
  is written out of order: this process handles its queue first.
  """
  @spec store(Run.t(), [map()], [map()]) :: {:ok, Run.t()} | {:error, term()}
  def store(%Run{} = run, log, timeline) do
    GenServer.call(__MODULE__, {:store, run, log, timeline}, :infinity)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    options
    |> Keyword.put_new(:name, __MODULE__)
    |> Keyword.put_new(:hibernate_after, @idle_after)
    |> then(&GenServer.start_link(__MODULE__, :ok, &1))
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_cast({:checkpoint, run, log, timeline, handed}, state) do
    case RunHistory.checkpoint_steps(run, log, timeline, timeline: :skip) do
      {:ok, _saved} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "studio run #{run.id}: cannot write the steps up to #{handed}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_cast({:alive, run}, state) do
    RunHistory.alive(run)
    {:noreply, state}
  end

  @impl true
  def handle_call({:store, run, log, timeline}, _from, state) do
    {:reply, RunHistory.store(run, log, timeline), state}
  end
end
