defmodule Monty.Frameworks.Loggers.WandbHandlers.WandbWrapper do
  @moduledoc """
  `tbp/monty/frameworks/loggers/wandb_handlers.py::WandbWrapper`.

  The handler that owns the wandb run: it hands the episode to each wandb handler
  in turn, and only then commits, so every table and every number of one episode
  lands as one step of the run instead of as one step per handler.

  The handlers it wraps are built by `Monty.Studio.Logging` and handed in — a
  config's nested `_target_`s are built wherever they appear, not only at the top
  — so this module knows nothing of classes or of the module map, only the order
  of the commit.

  ## The run is opened lazily

  Monty's experiment calls `wandb_init(run_name, config)` before the first
  episode. Here the wrapper opens the run on the episode that first needs it, so
  a run whose logging is configured but that is stopped before reporting leaves
  no empty wandb run behind, and `close/1` has nothing to finish.
  """

  require Logger

  alias Monty.Frameworks.Loggers.MontyHandlers.MontyHandler
  alias Monty.Frameworks.Loggers.WandbHandlers.PythonxClient

  @behaviour MontyHandler

  @type t :: %__MODULE__{}

  defstruct client: PythonxClient,
            handlers: [],
            group: nil,
            resume_wandb_run: false,
            wandb_id: "",
            run_name: nil,
            config: %{},
            run: nil,
            reported: 0

  @doc """
  Wraps `handlers`, optionally naming the run and replacing the client.

  `:client` is an option rather than a config key: a config names Monty classes,
  and the transport is this port's, not Monty's.
  """
  @spec new([struct()], keyword()) :: t()
  def new(handlers, options \\ []) do
    %__MODULE__{
      handlers: handlers,
      group: Keyword.get(options, :group),
      resume_wandb_run: Keyword.get(options, :resume_wandb_run, false),
      wandb_id: Keyword.get(options, :wandb_id) || "",
      run_name: Keyword.get(options, :run_name),
      config: Keyword.get(options, :config, %{}),
      client: Keyword.get(options, :client, PythonxClient)
    }
  end

  @impl MontyHandler
  def from_config(config) do
    %__MODULE__{
      handlers: Map.get(config, "wandb_handlers", []),
      group: Map.get(config, "wandb_group"),
      resume_wandb_run: Map.get(config, "resume_wandb_run", false),
      wandb_id: id(Map.get(config, "wandb_id")),
      run_name: Map.get(config, "run_name"),
      config: Map.get(config, "config", %{})
    }
  end

  @doc """
  What the wrapper itself filters out of the logs: nothing.

  Monty answers `""`, which is neither level; a handler has to answer one of the
  two here, and `:basic` is the honest one — the wrapper keeps nothing back. What
  it wraps is not hidden from `Monty.Studio.Logging`, which asks a wrapper's
  children whether the run needs the detailed pool.
  """
  @impl MontyHandler
  def log_level, do: :basic

  # `wandb_id: ${wandb.util.generate_id:}` is a call in Monty's config, and a
  # call is not an id: a run that has no id of its own is one wandb names.
  defp id(wandb_id) when is_binary(wandb_id), do: wandb_id
  defp id(_not_an_id), do: ""

  @doc """
  Opens the run, unless one is already open.

  Monty passes `id=self.wandb_id or ""`; an empty id means "let wandb name the
  run", which is what the client does with it.
  """
  @spec init(t(), String.t() | nil, map()) :: {:ok, t()} | {:error, term()}
  def init(%__MODULE__{run: run} = wrapper, _run_name, _config) when not is_nil(run),
    do: {:ok, wrapper}

  def init(%__MODULE__{} = wrapper, run_name, config) do
    attributes = %{
      "name" => (run_name || wrapper.run_name || "monty") <> "_" <> wrapper.wandb_id,
      "group" => wrapper.group,
      "resume" => wrapper.resume_wandb_run,
      "id" => wrapper.wandb_id,
      "config" => config,
      "tags" => Map.get(config, "wandb_tags")
    }

    case wrapper.client.init(attributes) do
      {:ok, run} -> {:ok, %{wrapper | run: run, reported: 0}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MontyHandler
  def report_episode(
        %__MODULE__{handlers: []} = wrapper,
        _data,
        _output_dir,
        _episode,
        _mode,
        _episodes_to_total
      ),
      do: {:ok, wrapper}

  def report_episode(
        %__MODULE__{} = wrapper,
        data,
        output_dir,
        episode,
        mode,
        episodes_to_total
      ) do
    with {:ok, wrapper} <- init(wrapper, wrapper.run_name, wrapper.config),
         {:ok, handlers} <-
           report_all(wrapper.handlers, {data, output_dir, episode, mode, episodes_to_total}),
         {:ok, run} <- wrapper.client.log(wrapper.run, %{}) do
      {:ok, %{wrapper | handlers: handlers, run: run, reported: wrapper.reported + 1}}
    end
  end

  @impl MontyHandler
  def close(%__MODULE__{run: nil}), do: :ok

  def close(%__MODULE__{client: client, run: run}) do
    case client.finish(run) do
      :ok -> :ok
      {:error, reason} -> refused(reason)
    end
  end

  # A run that cannot be finished has already reported what it reported; there is
  # nobody left to fail, so the refusal is said and not raised.
  defp refused(reason) do
    Logger.warning("wandb: this run could not be finished: #{inspect(reason)}")
    :ok
  end

  # One episode is one step: a handler that fails stops the report before the
  # commit, so a run never holds a step whose numbers are half of an episode.
  defp report_all(handlers, arguments) do
    {data, output_dir, episode, mode, episodes_to_total} = arguments

    Enum.reduce_while(handlers, {:ok, []}, fn handler, {:ok, reported} ->
      case handler.__struct__.report_episode(
             handler,
             data,
             output_dir,
             episode,
             mode,
             episodes_to_total
           ) do
        {:ok, handler} -> {:cont, {:ok, [handler | reported]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reported} -> {:ok, Enum.reverse(reported)}
      {:error, reason} -> {:error, reason}
    end
  end
end
