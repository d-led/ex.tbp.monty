defmodule Monty.Random.Stream do
  @moduledoc """
  The one random stream an episode draws from.

  Monty threads a single mutable `numpy.random.RandomState` through every module
  (`ctx.rng`), so what a module draws depends on how many draws the modules
  before it made. That object is shared and mutable, which is why it is a process
  here: one per model, holding a `Monty.Random.Numpy` state, reseeded when the
  episode's seed changes.

  Reached through `Monty.Context.rng`, a module draws in the order it is stepped.
  That order is Monty's — sensor modules, then learning modules' goals, then the
  motor system — and it is why the coordinator steps its sensor modules one at a
  time: a barrier would decide which module drew first by which call arrived
  first, and the numbers would follow the scheduler.

  A draw is a call, so this is the one place in a step where a module is not a
  pure function of its inputs; what it stays is a function of the episode, and
  two runs of the same episode draw the same numbers in the same order.
  """

  use GenServer

  alias Monty.Random.Numpy
  alias Monty.Runtime.Registry

  @type server :: GenServer.server()

  @doc "Starts the stream a model's episodes draw from."
  @spec start_link(%{model_id: atom() | String.t(), seed: non_neg_integer()}) ::
          GenServer.on_start()
  def start_link(%{model_id: model_id} = options) do
    GenServer.start_link(__MODULE__, Map.get(options, :seed, 0), name: via(model_id))
  end

  @doc "A `:via` name for a model's stream."
  @spec via(atom() | String.t()) :: {:via, module(), {atom(), term()}}
  def via(model_id), do: Registry.via({:random_stream, model_id})

  @doc "Starts the episode `seed` names, discarding the one before it."
  @spec reseed(server(), non_neg_integer()) :: :ok
  def reseed(server, seed), do: GenServer.call(server, {:reseed, seed})

  @doc "A float drawn uniformly from `[0, 1)`: Monty's `ctx.rng.uniform()`."
  @spec random(server()) :: float()
  def random(server), do: GenServer.call(server, :random)

  @doc "A float drawn uniformly from `[low, high)`: Monty's `ctx.rng.uniform(a, b)`."
  @spec uniform(server(), float(), float()) :: float()
  def uniform(server, low, high), do: GenServer.call(server, {:uniform, low, high})

  @doc "One normal draw: Monty's `ctx.rng.normal(loc=..., scale=...)`."
  @spec normal(server(), float(), float()) :: float()
  def normal(server, loc, scale), do: GenServer.call(server, {:normal, loc, scale})

  @doc "`count` normal draws: Monty's `ctx.rng.normal(loc=..., scale=..., size=count)`."
  @spec normals(server(), non_neg_integer(), float(), float()) :: [float()]
  def normals(server, count, loc, scale),
    do: GenServer.call(server, {:normals, count, loc, scale})

  @doc "The stream's own state, for a test that has to say where it is."
  @spec state(server()) :: Numpy.t()
  def state(server), do: GenServer.call(server, :state)

  @impl true
  def init(seed), do: {:ok, Numpy.new(seed)}

  @impl true
  def handle_call({:reseed, seed}, _from, _state),
    do: {:reply, :ok, Numpy.new(seed)}

  def handle_call(:random, _from, state) do
    {draw, state} = Numpy.random_sample(state)

    {:reply, draw, state}
  end

  def handle_call({:uniform, low, high}, _from, state) do
    {draw, state} = Numpy.uniform(state, low, high)

    {:reply, draw, state}
  end

  def handle_call({:normal, loc, scale}, _from, state) do
    {draw, state} = Numpy.normal(state, loc, scale)

    {:reply, draw, state}
  end

  def handle_call({:normals, count, loc, scale}, _from, state) do
    {draws, state} = Numpy.normals(state, count, loc, scale)

    {:reply, draws, state}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}
end
