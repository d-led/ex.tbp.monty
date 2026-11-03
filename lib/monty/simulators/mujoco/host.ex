defmodule Monty.Simulators.Mujoco.Host do
  @moduledoc """
  The MuJoCo world, in the interpreter this application carries.

  `priv/monty_py/world.py` is the world: a scene built from a spec, the agents
  that live in it, their cameras and their actuations, written against `mujoco`
  the same way Monty's `MuJoCoSimulator` is (numpy and numpy-quaternion for the
  arithmetic, and nothing else). It builds a world from JSON and answers a JSON
  header with the arrays' bytes behind it (`Monty.Simulators.Mujoco.Answer`),
  and `pythonx` is the interpreter — built at compile time by
  `config/pythonx.exs`, shipped inside the release. So a run steps Monty's
  world without a Monty checkout and without installing `tbp.monty`: the code
  travels with this application instead.

  ## Why one process

  A world is a MuJoCo model, the agents that live in it and the renderers they
  look through — one sequence of state. Two runs interleaving inside a step
  would each see the other's scene, so every world lives in this one process and
  a step is atomic with respect to any other. Worlds are addressed by id, so a
  run keeps its own and stops it when it ends.

  Renders are MuJoCo's own C calls, which release Python's GIL: that is why a
  single `Pythonx.eval/2` is *not* enough on its own, and why the sequencing
  lives here rather than at each call site.
  """

  use GenServer

  alias Monty.Simulators.Mujoco.Answer

  @name __MODULE__

  # A step renders one frame per sensor; the first also compiles the scene and
  # builds the agent's bodies. A minute would be a hang, not a slow step.
  @timeout 120_000

  @bootstrap """
  import json
  import sys

  sys.path.insert(0, json.loads(search_path))
  import world as monty_world
  """

  @new_world "world = monty_world.World(spec)"
  @reset "answer = world.reset()"
  @step "answer = world.step(actions)"
  @close "world.close()"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: @name)

  @doc "Builds a world from `spec` and keeps it under `id`."
  @spec start_world(String.t(), map()) :: :ok | {:error, String.t()}
  def start_world(id, spec), do: GenServer.call(@name, {:start_world, id, spec}, @timeout)

  @doc "The first step of an episode, with what the episode is about."
  @spec reset(String.t()) :: {:ok, map()} | {:error, String.t()}
  def reset(id), do: GenServer.call(@name, {:reset, id}, @timeout)

  @doc "One step: the actions the model chose, and what the sensors see after."
  @spec step(String.t(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def step(id, actions), do: GenServer.call(@name, {:step, id, actions}, @timeout)

  @doc "Closes a world: its model, its renderers and its agents go with it."
  @spec stop_world(String.t()) :: :ok
  def stop_world(id), do: GenServer.call(@name, {:stop_world, id}, @timeout)

  @impl true
  def init(_options), do: {:ok, %{globals: nil, worlds: %{}}}

  @impl true
  def handle_call({:start_world, id, spec}, _from, state) do
    with {:ok, globals} <- boot(state.globals),
         {:ok, globals} <- evaluate(@new_world, Map.put(globals, "spec", Jason.encode!(spec))) do
      {:reply, :ok, %{state | globals: globals, worlds: Map.put(state.worlds, id, globals)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, %{state | globals: nil}}
    end
  end

  def handle_call({:reset, id}, _from, state) do
    with {:ok, globals} <- world(state, id),
         {:ok, globals} <- evaluate(@reset, globals) do
      {:reply, {:ok, answer(globals)},
       %{state | globals: globals, worlds: put(state, id, globals)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:step, id, actions}, _from, state) do
    with {:ok, globals} <- world(state, id),
         {:ok, globals} <-
           evaluate(@step, Map.put(globals, "actions", Jason.encode!(actions))) do
      {:reply, {:ok, answer(globals)},
       %{state | globals: globals, worlds: put(state, id, globals)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_world, id}, _from, state) do
    case Map.fetch(state.worlds, id) do
      {:ok, globals} ->
        _ = evaluate(@close, globals)
        {:reply, :ok, %{state | worlds: Map.delete(state.worlds, id)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  defp world(state, id) do
    case Map.fetch(state.worlds, id) do
      {:ok, globals} -> {:ok, globals}
      :error -> {:error, "this run's world is not open — the simulator was closed with it"}
    end
  end

  defp put(state, id, globals), do: Map.put(state.worlds, id, globals)

  defp boot(nil), do: evaluate(@bootstrap, %{"search_path" => Jason.encode!(directory())})
  defp boot(globals), do: {:ok, globals}

  defp answer(globals), do: globals |> Map.fetch!("answer") |> Pythonx.decode() |> Answer.decode()

  defp evaluate(code, variables) do
    {_result, globals} = Pythonx.eval(code, variables)
    {:ok, globals}
  rescue
    exception -> {:error, "Monty's MuJoCo simulator failed: #{Exception.message(exception)}"}
  end

  # Shipped Python is read from the release's `priv/`, which is where the build
  # put it — never from a path relative to the working directory, which a
  # release does not have.
  defp directory, do: :ex_tbp_monty |> :code.priv_dir() |> Path.join("monty_py")
end
