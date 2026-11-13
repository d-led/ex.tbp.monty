defmodule Monty.Studio.Jobs.Stops do
  @moduledoc """
  Which runs have been asked to stop.

  A run is performed by one worker, and its steps happen in the tasks that worker
  starts — one per part of a divided run, one for the whole of an undivided one.
  A task's mailbox is not the worker's, so a stop written to the worker is read
  only where the worker itself looks: between waves, which for a run of one part
  is after a whole phase. A page's Stop then looks like it did nothing at all for
  as long as the phase lasts, and the run settles as `stopped` long after whoever
  pressed the button gave up waiting.

  So the ask is kept here instead, where every process of the run can read it:
  one row per run that was asked, written when the page asks and read at every
  step, cleared when the run closes. It is a table rather than a message because
  a message can only be read once, and the question "has this run been asked to
  stop" is asked by every step of every part.
  """

  use GenServer

  @table __MODULE__

  @doc """
  The run was asked to stop.

  Called from whichever process took the ask — a page, a tool, a peer's call —
  and read by the processes stepping the run.
  """
  @spec ask(binary()) :: :ok
  def ask(run_id) do
    :ets.insert(@table, {run_id})
    :ok
  end

  @doc "Whether the run was asked to stop."
  @spec asked?(binary()) :: boolean()
  def asked?(run_id), do: :ets.member(@table, run_id)

  @doc """
  The run has closed: nothing will read its flag again.

  Called where the run unregisters its owner, so a run of the same id started
  later — a replay, a second attempt — is not stopped by the last one's ask.
  """
  @spec clear(binary()) :: :ok
  def clear(run_id) do
    :ets.delete(@table, run_id)
    :ok
  end

  @impl true
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    _table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
