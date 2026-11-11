defmodule Monty.Studio.Readiness.Cache do
  @moduledoc """
  The survey, composed once.

  `Monty.Studio.Readiness.catalog/1` reads through a `:persistent_term`: correct,
  and free once the answer is there. What it does not do is single-flight — a node
  that has just started holds no answer, and every page asking at that moment
  composes all 132 configs itself. Measured on a fresh node: three concurrent
  first calls cost 3 × 3.8 s of scheduler time each, which is work a stepping run
  competes with, and a page pays for it by losing its connection.

  So asks come through one process. The first call composes, the others wait for
  it and are answered from the same cache. A caller that dies — a closed tab, a
  killed mount — takes nothing with it, because the composing happens here and not
  in the caller.

  Measured after it: three concurrent first asks compose once (3 × 3.8 s of
  scheduler work became 3.0 s), and every asker gets the same answer.

  It is an optimisation, not a dependency: a node whose supervisor does not carry
  this child — a development server that has not been restarted since it was
  added — composes in the caller, which is what every page did before.
  """

  use GenServer

  alias Monty.Studio.Readiness

  @doc "The survey every experiment's answer is read from, composed at most once."
  @spec survey(keyword()) :: Readiness.survey()
  def survey(opts \\ []) do
    GenServer.call(__MODULE__, {:survey, opts}, :timer.minutes(5))
  catch
    # Nobody is supervising the cache, so there is nothing to wait for: the caller
    # composes its own copy, exactly as it did before this process existed. A page
    # that dies because an optimisation is absent is the worse failure.
    :exit, {:noproc, _} -> Readiness.catalog(opts)
  end

  @doc """
  How many times this process composed the survey.

  One per cold start is the point of it; a later number says the answer was
  invalidated — a new config, a download that landed, a memory that was exported —
  which is correct, and worth being able to see.
  """
  @spec compositions() :: non_neg_integer()
  def compositions, do: GenServer.call(__MODULE__, :compositions)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{composed: 0}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:survey, opts}, _from, state) do
    cold? = not Readiness.cached?(opts)
    survey = Readiness.catalog(opts)

    {:reply, survey, if(cold?, do: %{state | composed: state.composed + 1}, else: state)}
  end

  def handle_call(:compositions, _from, state), do: {:reply, state.composed, state}
end
