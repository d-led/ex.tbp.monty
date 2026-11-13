defmodule FlyversePlugin.Networks do
  @moduledoc """
  The connectome this node steps, opened once and shared.

  Two reasons for one process rather than a call at each use:

    * `Connectome::load` keeps the pack's arrays for the life of the VM
      (`Box::leak`), deliberately — a 24-million-edge graph cannot be copied per
      step. Opening a pack per episode would leak a few hundred megabytes an
      episode, so a pack is opened once per directory and answered from
      memory after that.
    * The plan beside it (`plan.json`) is small and read once with it, so a
      policy is never the place that decides what a pack's neuron 2 means.

  ## Which pack

  `FLYVERSE_PACK`, which is the variable flyverse's own binary reads, falling
  back to the application's `:pack` setting. A node with neither is not
  misconfigured — it is a node without the dataset — so the answer is a sentence
  naming the demonstrator (`mix flyverse_plugin.pack`), not a crash.
  """

  use GenServer

  require Logger

  alias FlyversePlugin.Native

  @variable "FLYVERSE_PACK"

  @doc false
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @doc """
  The pack this node steps: the connectome handle and the plan that goes with it.

  `{:ok, %{connectome: handle, plan: plan, directory: path}}`, or a sentence
  saying what to set. The handle is a NIF resource and belongs to this node.
  """
  @spec open() ::
          {:ok, %{connectome: term(), plan: map(), directory: String.t()}}
          | {:error, String.t()}
  def open, do: GenServer.call(__MODULE__, :open)

  @doc "The directory a pack would be opened from, or `nil` when none is named."
  @spec directory() :: String.t() | nil
  def directory do
    case System.get_env(@variable) || Application.get_env(:flyverse_plugin, :pack) do
      path when path in [nil, ""] -> nil
      path -> path
    end
  end

  @impl true
  def init(_options), do: {:ok, %{packs: %{}}}

  @impl true
  def handle_call(:open, _from, state) do
    case directory() do
      nil ->
        {:reply, {:error, no_pack()}, state}

      path ->
        {reply, state} = answered(path, state)
        {:reply, reply, state}
    end
  end

  # A directory is opened once. A refusal is remembered too: a pack that is
  # wrong now is wrong on every step of a run, and a run asks per policy, not
  # per page load.
  defp answered(path, %{packs: packs} = state) do
    case Map.fetch(packs, path) do
      {:ok, answer} ->
        {answer, state}

      :error ->
        answer = open_pack(path)
        log(path, answer)

        {answer, %{state | packs: Map.put(packs, path, answer)}}
    end
  end

  defp log(path, {:ok, %{census: census}}) do
    Logger.info(
      "flyverse plugin: pack #{path} holds #{census.neurons} neurons " <>
        "and #{census.edges} signed edges"
    )
  end

  defp log(_path, {:error, _sentence}), do: :ok

  defp open_pack(path) do
    with {:ok, plan} <- plan(path),
         {:ok, connectome} <- Native.open(path) do
      census =
        case Native.census(connectome) do
          {neurons, edges} -> %{neurons: neurons, edges: edges}
        end

      {:ok, %{connectome: connectome, plan: plan, directory: path, census: census}}
    end
  end

  # The plan says which indices a policy drives and reads. A pack from the
  # dataset has none — a group there is a name from
  # `male_cns_v1_neural_io.json`, not an index — so the sentence says how to
  # write one rather than inventing a wiring.
  defp plan(path) do
    file = Path.join(path, "plan.json")

    with {:ok, text} <- read(file),
         {:ok, document} <- decode(file, text) do
      validate_plan(file, document)
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, text} ->
        {:ok, text}

      {:error, :enoent} ->
        {:error,
         "#{Path.dirname(file)} is a connectome pack with no plan.json: the plan says which " <>
           "neurons a policy drives and reads, which is a fact about the pack. Write one — " <>
           ~s|{"drives": [[<indices>], ...], "readouts": [[<indices>], ...], "ticks": 20, | <>
           ~s|"seed": 7} — or point FLYVERSE_PACK at the demonstrator `mix flyverse_plugin.pack` | <>
           "writes."}

      {:error, reason} ->
        {:error, "the plan #{file} could not be read: #{:file.format_error(reason)}"}
    end
  end

  defp decode(file, text) do
    case Jason.decode(text) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, other} -> {:error, "the plan #{file} is #{inspect(other)}, and a plan is an object"}
      {:error, error} -> {:error, "the plan #{file} is not JSON: #{Exception.message(error)}"}
    end
  end

  defp validate_plan(file, document) do
    with {:ok, drives} <- indices(file, document, "drives"),
         {:ok, readouts} <- indices(file, document, "readouts") do
      {:ok,
       %{
         drives: drives,
         readouts: readouts,
         ticks: positive_integer(document, "ticks", 20),
         seed: non_negative_integer(document, "seed", 0)
       }}
    end
  end

  defp indices(file, document, key) do
    case Map.get(document, key) do
      groups when is_list(groups) and groups != [] ->
        if Enum.all?(groups, &is_list/1) and Enum.all?(List.flatten(groups), &non_negative?/1) do
          {:ok, groups}
        else
          {:error, "`#{key}` in #{file} is a list of lists of model indices, and this is not"}
        end

      _missing ->
        {:error, "`#{key}` is missing from #{file}, and a plan without it names no neurons"}
    end
  end

  defp non_negative?(value), do: is_integer(value) and value >= 0

  defp positive_integer(document, key, default) do
    case Map.get(document, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp non_negative_integer(document, key, default) do
    case Map.get(document, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp no_pack do
    "no connectome pack is named: set #{@variable} to a flyverse pack, or write the " <>
      "demonstrator into a directory of your own with " <>
      "`mix flyverse_plugin.pack <directory>` and point #{@variable} at it. The plugin " <>
      "does not invent a connectome to stand in for one."
  end
end
