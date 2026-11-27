defmodule Monty.Telemetry.Collector do
  @moduledoc """
  The events a run emitted, held where a reader can walk them.

  This module is **not** Monty's: `tbp/monty/telemetry` writes its events to
  `logging` handlers, and Monty's dashboard reads them off a ZMQ publisher
  (`contrib/liveview_experiment`, and `docs/monty-differences.md` §2.49). The
  studio has neither a socket nor a subscriber, so this is the port's own way of
  answering the same question — what did the run say — and the shape is
  deliberately the one a chart wants: records in the order they were emitted,
  each keeping the publisher's name and the event.

  A collector is optional. `record/1` answers `:no_collector` when none is
  running, so a run that is not being watched does no work and starts no
  process; `Monty.Telemetry.Publishers.TelemetryPublisher.emit/3` calls it on
  every event.

  ## Bounded on purpose

  A run can emit an event per step for hours. The collector keeps the most
  recent `:max` records (ten thousand by default) and counts what it has
  dropped, so a page showing the last few minutes cannot grow without limit —
  the same ceiling the run logs have.
  """

  use GenServer

  @name __MODULE__
  @max 10_000

  @typedoc "A record: the publisher's name, the level, and the event."
  @type t :: %{
          required(:level) => atom(),
          required(:name) => String.t(),
          required(:func_name) => String.t(),
          required(:lineno) => non_neg_integer(),
          required(:msg) => Monty.Telemetry.Schemas.TelemetryEvent.t()
        }

  @doc "Starts the collector a run's events are recorded into."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(@name, options, name: Keyword.get(options, :name, @name))
  end

  @doc "A supervisor child for a run's telemetry, with the default name."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, @name),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @doc """
  Records one event, if a collector is running.

  `:no_collector` is not an error: a run nobody is watching still emits.
  """
  @spec record(t()) :: :ok | :no_collector
  def record(%{name: _} = record) do
    case GenServer.whereis(@name) do
      nil -> :no_collector
      pid -> GenServer.cast(pid, {:record, record})
    end
  end

  @doc "Every record kept, oldest first."
  @spec events() :: [t()]
  def events, do: GenServer.call(@name, :events)

  @doc "The records one publisher emitted, oldest first."
  @spec events(String.t()) :: [t()]
  def events(publisher) do
    GenServer.call(@name, {:events, publisher})
  end

  @doc "How many records are kept, and how many were dropped before them."
  @spec counts() :: %{kept: non_neg_integer(), dropped: non_neg_integer()}
  def counts, do: GenServer.call(@name, :counts)

  @doc "Forgets every record, which is what a new episode does."
  @spec clear() :: :ok
  def clear, do: GenServer.call(@name, :clear)

  ## The process

  @impl true
  def init(options) do
    {:ok, %{max: Keyword.get(options, :max, @max), records: :queue.new(), dropped: 0}}
  end

  @impl true
  def handle_cast({:record, record}, state) do
    %{max: max, records: records, dropped: dropped} = state
    records = :queue.in(record, records)

    {records, dropped} =
      if :queue.len(records) > max do
        {:queue.drop(records), dropped + 1}
      else
        {records, dropped}
      end

    {:noreply, %{state | records: records, dropped: dropped}}
  end

  @impl true
  def handle_call(:events, _from, state), do: {:reply, :queue.to_list(state.records), state}

  def handle_call({:events, publisher}, _from, state) do
    kept = state.records |> :queue.to_list() |> Enum.filter(&(&1.name == publisher))
    {:reply, kept, state}
  end

  def handle_call(:counts, _from, state) do
    {:reply, %{kept: :queue.len(state.records), dropped: state.dropped}, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | records: :queue.new(), dropped: 0}}
  end
end
