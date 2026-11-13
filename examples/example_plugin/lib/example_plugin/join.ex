defmodule ExamplePlugin.Join do
  @moduledoc """
  The node, joining the cluster the studio is in — from the environment.

  Two variables, and they are the ones a studio node reads, because one secret
  written in two spellings is a cluster that stays silently separate:

    * `MONTY_CLUSTER_SECRET` — the cookie. Set before the first connection is
      attempted, since a connection is made with whatever cookie the node holds
      at the time.
    * `MONTY_SEEDS` — the nodes to reach, comma-separated, in the spelling a
      person copies out of a peer's Settings page (`node1@10.0.0.7`).

  The node's **own** name is not here: a VM is named with `--name` before any of
  this code runs, and it cannot be renamed afterwards. So `--name` says what this
  node is called and the environment says what it joins — see
  `process-compose.yaml`.

  ## Why it retries

  The processes of a `process-compose` project start in the order the file lists
  them and a studio node takes a good deal longer to boot than this one: the
  first attempt happens while the node it wants is still compiling. So a seed
  that is not reached is tried again, and what is logged is a *change* in what
  has been reached rather than one line per attempt — a plugin that shouted every
  five seconds about a node that was still booting would make the interesting
  lines unfindable.

  A node that runs alone is untouched: with no seeds this process has nothing to
  try, and the plugins are registered on this node exactly as they would be in a
  cluster of one.
  """

  use GenServer

  require Logger

  @retry_ms 5_000
  @variable "MONTY_SEEDS"

  @doc false
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @impl true
  def init(_options) do
    state = %{seeds: seeds(), reached: []}
    send(self(), :join)
    {:ok, state}
  end

  @impl true
  def handle_info(:join, state) do
    set_cookie()

    reached = reach(state.seeds)

    if reached != state.reached do
      Logger.info("example plugin: #{describe(reached)}")
    end

    schedule()

    {:noreply, %{state | reached: reached}}
  end

  defp schedule, do: Process.send_after(self(), :join, @retry_ms)

  @doc """
  The nodes named in `MONTY_SEEDS`, as the atoms OTP uses.

  Empty when the variable is unset or blank, which is a node that runs alone
  rather than a mistake: the same code is started in a test with no cluster at
  all.
  """
  @spec seeds() :: [node()]
  def seeds do
    @variable
    |> System.get_env("")
    |> String.split(",", trim: true)
    # One atom per node name, made when this process starts from a value a
    # deployment wrote: the table grows by the size of the cluster, not by the
    # size of anybody's traffic.
    |> Enum.map(&(&1 |> String.trim() |> atom()))
  end

  # The cookie is read on every attempt rather than cached: `MONTY_CLUSTER_SECRET`
  # is what a deployment hands over, and a process that cached the first answer
  # would ignore a change that a restart was meant to apply.
  #
  # `Node.set_cookie/1` raises on a VM that was never named, and a node without a
  # name joins nothing, so there is nothing to set. It answers `true` when it has
  # set one, which is not a value worth matching on: the cookie is set for its
  # effect.
  defp set_cookie do
    with true <- Node.alive?(),
         secret when secret not in [nil, ""] <- System.get_env("MONTY_CLUSTER_SECRET") do
      Node.set_cookie(atom(secret))
      :ok
    else
      _unnamed_or_no_secret -> :ok
    end
  end

  # `:erlang.binary_to_atom/2` rather than `String.to_atom/1`: these are node
  # names and a cookie, written by whoever deployed this, and the explicit call
  # says the atom is deliberate.
  defp atom(text), do: :erlang.binary_to_atom(text, :utf8)

  defp reach(seeds) do
    seeds
    |> Enum.filter(fn seed -> seed in Node.list() or Node.connect(seed) end)
    |> Enum.sort()
  end

  defp describe([]), do: "not in a cluster (no seed answered from #{@variable})"

  defp describe(reached),
    do: "in a cluster with #{Enum.map_join(reached, ", ", &to_string/1)}"
end
