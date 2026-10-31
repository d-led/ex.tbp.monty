defmodule Monty.Frameworks.Loggers.MontyHandlers.DetailedJSONHandler do
  @moduledoc """
  `tbp/monty/frameworks/loggers/monty_handlers.py::DetailedJSONHandler`.

  The episode in full: the DETAILED logs a learning module produced, merged under
  the BASIC stats for the same episode and written as JSON — either one file per
  episode (`detailed_run_stats/episode_000003.json`) or one growing
  `detailed_run_stats.json`.

  What is written is keyed by the run's episode id, not the local one: an
  experiment trains and then evaluates, so `local_episode` restarts at 0 when the
  mode changes while `episodes_to_total` says where in the run this episode
  actually is. A file keyed by the local id would collide the train and eval
  halves of the same run.

  The single-file form is Monty's, and it is a stream of JSON objects rather than
  one document — a run appends to it and a reader takes it a line at a time,
  which is why the file is renamed to `_old` once, when the run starts.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode
  alias Monty.Frameworks.Loggers.MontyHandlers.MontyHandler
  alias Monty.Frameworks.Models.Buffer.BufferEncoder
  alias Monty.Frameworks.Utils.LoggingUtils

  @behaviour MontyHandler

  defstruct detailed_episodes_to_save: :all, detailed_save_per_episode: false, renamed?: false

  @typedoc """
  Which episodes to write, and whether each gets its own file.

  `detailed_episodes_to_save` is `:all` or a list of global episode ids, exactly
  as Monty's `"all"` or a container of integers.
  """
  @type t :: %__MODULE__{
          detailed_episodes_to_save: :all | [integer()],
          detailed_save_per_episode: boolean(),
          renamed?: boolean()
        }

  @doc """
  A handler for the episodes named, one file each, or all of them in one file.

  Options are Monty's two arguments by name: `:detailed_episodes_to_save`
  (`:all` by default) and `:detailed_save_per_episode` (`false` by default).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      detailed_episodes_to_save: Keyword.get(opts, :detailed_episodes_to_save, :all),
      detailed_save_per_episode: Keyword.get(opts, :detailed_save_per_episode, false)
    }
  end

  @doc "`MontyHandler.from_config/1`: the two keywords Monty's constructor takes."
  @impl MontyHandler
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      detailed_episodes_to_save:
        episodes_to_save(Map.get(config, "detailed_episodes_to_save", "all")),
      detailed_save_per_episode: Map.get(config, "detailed_save_per_episode", false)
    )
  end

  defp episodes_to_save("all"), do: :all
  defp episodes_to_save(episodes) when is_list(episodes), do: episodes

  @doc "`MontyHandler.log_level/0`: this handler filters out the DETAILED logs."
  @impl MontyHandler
  @spec log_level() :: :detailed
  def log_level, do: :detailed

  @doc """
  Writes one episode, if this handler was asked for it.
  """
  # The path is the run's own results directory plus a file name this handler
  # makes from an episode id, so nothing here comes from outside the run.
  # sobelow_skip ["Traversal.FileModule"]
  @impl MontyHandler
  @spec report_episode(t(), map(), Path.t(), non_neg_integer(), ExperimentMode.t(), map()) ::
          {:ok, t()} | {:error, term()}
  def report_episode(
        %__MODULE__{} = handler,
        data,
        output_dir,
        local_episode,
        mode,
        episodes_to_total
      ) do
    global_episode_id = Map.get(episodes_to_total, local_episode)

    if save?(handler, global_episode_id) do
      with {:ok, stats} <- episode_stats(data, global_episode_id, local_episode, mode) do
        write(handler, output_dir, global_episode_id, stats)
      end
    else
      {:ok, handler}
    end
  end

  @doc "Nothing is held open: each report has written its own file."
  @impl MontyHandler
  @spec close(t()) :: :ok
  def close(%__MODULE__{}), do: :ok

  # `_should_save_episode`: `"all"` or the episode is one of the ones named.
  defp save?(%__MODULE__{detailed_episodes_to_save: :all}, _global_episode_id), do: true

  defp save?(%__MODULE__{detailed_episodes_to_save: episodes}, global_episode_id),
    do: global_episode_id in episodes

  # `get_detailed_stats`: the BASIC stats for this episode, with the DETAILED
  # logs merged over them. Monty falls back to the pool keyed by the global id,
  # which is what a detailed logger that never saw a mode change writes.
  defp episode_stats(data, global_episode_id, local_episode, mode) do
    basic =
      data |> Map.get("BASIC", %{}) |> Map.get("#{ExperimentMode.to_string(mode)}_stats", %{})

    detailed = Map.get(data, "DETAILED", %{})

    case Map.fetch(basic, local_episode) do
      {:ok, episode} ->
        with {:ok, pool} <- detailed_stats(detailed, global_episode_id, local_episode) do
          {:ok, Map.merge(episode, pool)}
        end

      :error ->
        {:error, {:no_basic_stats, local_episode}}
    end
  end

  defp detailed_stats(detailed, global_episode_id, local_episode) do
    case Map.get(detailed, local_episode) || Map.get(detailed, global_episode_id) do
      nil -> {:error, {:no_detailed_stats, global_episode_id}}
      stats -> {:ok, stats}
    end
  end

  # `<output_dir>/detailed_run_stats/episode_<id>.json`, both halves made here
  # from the run's own directory and an episode id.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(%__MODULE__{detailed_save_per_episode: true} = handler, output_dir, id, stats) do
    directory = Path.join(output_dir, "detailed_run_stats")
    path = Path.join(directory, "episode_#{String.pad_leading(to_string(id), 6, "0")}.json")

    File.mkdir_p!(directory)
    :ok = LoggingUtils.maybe_rename_existing_file(path)

    with :ok <- File.write(path, encode(id, stats)) do
      {:ok, handler}
    end
  end

  # `<output_dir>/detailed_run_stats.json`, the run's own directory and a fixed
  # file name.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(%__MODULE__{} = handler, output_dir, id, stats) do
    path = Path.join(output_dir, "detailed_run_stats.json")

    handler =
      if handler.renamed? do
        handler
      else
        :ok = LoggingUtils.maybe_rename_existing_file(path)
        %{handler | renamed?: true}
      end

    # One JSON object per line: Monty appends to this file for the whole run, and
    # a reader takes it a line at a time.
    with :ok <- File.write(path, encode(id, stats) <> "\n", [:append]) do
      {:ok, handler}
    end
  end

  defp encode(global_episode_id, stats) do
    %{global_episode_id => BufferEncoder.encode(stats)} |> Jason.encode!()
  end
end
