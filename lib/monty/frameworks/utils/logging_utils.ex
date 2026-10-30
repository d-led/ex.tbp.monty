defmodule Monty.Frameworks.Utils.LoggingUtils do
  @moduledoc """
  `tbp/monty/frameworks/utils/logging_utils.py`: what the loggers write with.

  The Python file is the largest in Monty's framework, and most of it is pandas
  shape-shifting and plotting (`lm_stats_to_dataframe`, `get_rgba_frames_single_sm`,
  the buffer-size recipe `total_size`) that exists to feed a notebook. What is
  here is the part a logger cannot do without, ported as it is needed rather than
  as it appears:

    * `maybe_rename_existing_file/1` and `maybe_rename_existing_dir/1` — a run's
      files belong to that run, so what a previous run left is moved aside, once,
      with a `_old` suffix. Every handler that writes a file needs this, which is
      why it is here and not copied into each of them.
    * `target_data_to_dict/1` — the primary target as the columns a CSV carries:
      object, position, rotation, scale.

  `total_size/1` is deliberately absent: Monty keeps it for the size-based logging
  it removed (`maybe_log` is dead code with a "remove if not used" note), and a
  memory-footprint recipe has nothing to do in a language that does not flatten
  objects into dicts.

  ## Differences from Monty, on purpose

    * The renames return `:ok` or `{:error, reason}` instead of raising (Python
      raises on a directory that is not one). A logger that cannot move a file
      aside can still report the reason and stop, which the fan-out already
      handles; a raise from inside a callback loses the rest of the episode.
    * A target key that is absent is `nil` rather than a `KeyError`: it becomes an
      empty cell in the CSV, which is the truth — the run did not have a position
      to record — where a crash would take the whole episode with it.
  """

  @doc """
  Moves `path` to `<name>_old<ext>` if it exists, replacing an older `_old`.

  One `_old`, not a pile of them: a run that has been restarted three times is
  still one previous run.
  """
  # `path` is the run's own output file, built from the run's directory.
  # sobelow_skip ["Traversal.FileModule"]
  @spec maybe_rename_existing_file(Path.t()) :: :ok | {:error, term()}
  def maybe_rename_existing_file(path) do
    if File.exists?(path) do
      old = Path.rootname(path) <> "_old" <> Path.extname(path)

      with :ok <- remove_if_present(old), do: rename(path, old)
    else
      :ok
    end
  end

  @doc """
  Moves `path` to `<name>_old` if it is a directory, replacing an older `_old`.

  A path that exists and is not a directory is `{:error, {:not_a_directory, path}}`
  — the caller asked for a directory to be moved aside and got a file, which is a
  run set up wrong rather than a run with nothing to do.
  """
  # `path` is the run's own output directory, built from the run's directory.
  # sobelow_skip ["Traversal.FileModule"]
  @spec maybe_rename_existing_dir(Path.t()) :: :ok | {:error, term()}
  def maybe_rename_existing_dir(path) do
    cond do
      not File.exists?(path) ->
        :ok

      not File.dir?(path) ->
        {:error, {:not_a_directory, path}}

      true ->
        old = Path.join(Path.dirname(path), Path.basename(path) <> "_old")

        with :ok <- remove_dir_if_present(old), do: rename(path, old)
    end
  end

  @doc """
  The primary target as the columns a CSV carries.

  Monty reads `object`, `position`, `euler_rotation`, `rotation` and `scale` off
  the environment's target and names them `primary_target_*`, because those are
  the names its readers filter on. Scale is uniform along every dimension, so only
  its first entry is recorded.
  """
  @spec target_data_to_dict(map()) :: %{optional(String.t()) => term()}
  def target_data_to_dict(target) do
    %{
      "primary_target_object" => Map.get(target, "object"),
      "primary_target_position" => Map.get(target, "position"),
      "primary_target_rotation_euler" => Map.get(target, "euler_rotation"),
      "primary_target_rotation_quat" => Map.get(target, "rotation"),
      "primary_target_scale" => target |> Map.get("scale", []) |> List.first()
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_if_present(path) do
    if File.exists?(path), do: File.rm(path), else: :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_dir_if_present(path) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _removed} -> :ok
        {:error, reason, file} -> {:error, {reason, file}}
      end
    else
      :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(path, to) do
    case File.rename(path, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {reason, path}}
    end
  end
end
