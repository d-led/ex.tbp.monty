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
    * `compute_pose_error/3` — how far a recognition's pose was from the pose the
      object was placed with, which is the `rotation_error` a CSV column holds.

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

  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Geometry.Rotation

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
  The angular error between a predicted rotation and the target's.

  Monty's `compute_pose_error`, which is the smallest of `compute_pose_errors`: the
  geodesic distance on SO(3), the angle of the relative rotation. It is what a
  recognition's `rotation_error` is, so a run's pose accuracy is this number and
  not a difference of Euler angles — two rotations can differ by nought in every
  Euler angle and still be different rotations.

  `predicted` may be a list, in which case the closest one wins, which is Monty's
  `np.min` over the errors: a symmetric object seen at any of its equivalent poses
  is not wrong.
  """
  @spec compute_pose_error(Rotation.t() | [Rotation.t()], Rotation.t(), keyword()) :: float()
  def compute_pose_error(predicted, target, options \\ []) do
    error =
      predicted
      |> List.wrap()
      |> Enum.map(fn rotation ->
        rotation |> Rotation.multiply(Rotation.invert(target)) |> Rotation.magnitude()
      end)
      |> Enum.min()

    if Keyword.get(options, :degrees, false), do: error * 180 / :math.pi(), else: error
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

  @doc """
  `format_columns_for_wandb`: the one column a table cannot take as it is.

  Monty's words: "various columns break wandb because we are playing fast and loose
  with types". A result is a list of object names, and a list in a cell makes a
  table column whose type depends on the row; joined with `^` it stays a string in
  every row. Everything else is passed through.

  Monty deep-copies first, because Python mutates a dict in place. A map here is
  already a value, so there is nothing to copy and nothing to be careful about —
  which is the only difference between the two.
  """
  @spec format_columns_for_wandb(map()) :: map()
  def format_columns_for_wandb(lm_stats) do
    case Map.get(lm_stats, "result") do
      result when is_list(result) -> Map.put(lm_stats, "result", Enum.join(result, "^"))
      _not_a_list -> lm_stats
    end
  end

  @doc """
  `get_stats_per_lm`: every learning module's stats for one episode.

  Keyed `LM_0`, `LM_1` … by the module's position, which is the key Monty's CSV
  rows and its `lm_id` column are written from, and each module's stats carry the
  run's step counts, the episode's seed and the target — because a row that cannot
  say which object it was about cannot be compared with one that can.

  Options: `:step` and `:matching_steps`, the run's counters (Monty's
  `model.episode_steps` and `model.matching_steps`), and `:episode_seed`.
  """
  @spec stats_per_lm([struct()], map() | nil, keyword()) :: %{optional(String.t()) => map()}
  def stats_per_lm(learning_modules, primary_target, options \\ []) do
    run = %{
      "monty_steps" => Keyword.get(options, :step, 0),
      "monty_matching_steps" => Keyword.get(options, :matching_steps, 0),
      "episode_seed" => Keyword.get(options, :episode_seed)
    }

    target = target_data_to_dict(primary_target || %{})

    learning_modules
    |> Enum.with_index()
    |> Map.new(fn {lm, index} ->
      stats =
        lm
        |> graph_lm_episode_stats()
        |> Map.merge(Map.put(target, "stepwise_target_object", lm.stepwise_target_object))
        |> Map.merge(run)

      {"LM_#{index}", stats}
    end)
  end

  @doc """
  `get_graph_lm_episode_stats`: one episode's stats for one learning module.

  The performance is a judgement about an object, so it needs three things the
  module has to have been told or to have worked out: the object it was asked
  about (`primary_target`), the object it concluded (`detected_object`), and which
  objects the graph it matched was built from (`graph_id_to_target`). Without the
  last one there is no way to tell a recognition from a coincidence, which is why
  a training episode records it.

  A module that was never on an object reports `patch_off_object` and no steps: it
  was never in the episode, and calling that a failure would put a wrong number in
  a file someone averages.
  """
  @spec graph_lm_episode_stats(struct()) :: map()
  def graph_lm_episode_stats(lm) do
    performance = episode_performance(lm)
    individual = individual_ts_performance(lm)
    {location, rotation, scale} = detected_pose(lm)

    base = %{
      "primary_performance" => performance.primary,
      "stepwise_performance" => performance.stepwise,
      "num_steps" => performance.num_steps,
      "result" => performance.result,
      "rotation_error" => performance.rotation_error,
      "num_possible_matches" => length(performance.possible_matches),
      "detected_location" => location,
      "detected_rotation" => rotation,
      "detected_scale" => scale,
      "location_rel_body" => performance.location,
      "detected_path" => lm.buffer.stats["detected_path"],
      "symmetry_evidence" => lm.symmetry_evidence,
      "individual_ts_reached_at_step" => individual.step,
      "individual_ts_performance" => individual.performance,
      "individual_ts_rotation_error" => individual.rotation_error,
      "time" => total_time(lm.buffer.stats["time"])
    }

    Map.merge(
      base,
      unsupervised_stats(
        performance.possible_matches,
        lm.primary_target,
        lm.graph_id_to_target,
        lm.target_to_graph_id
      )
    )
  end

  # A module that was never on an object: Monty's defaults, which say the episode
  # said nothing about it rather than that it did badly.
  @off_object %{
    primary: "patch_off_object",
    stepwise: "patch_off_object",
    result: nil,
    rotation_error: nil,
    possible_matches: [],
    num_steps: 0,
    location: [0, 0, 0]
  }

  defp episode_performance(lm) do
    # Monty's guard: the first step's `on_object` is what says the episode ever
    # reached the object.
    if lm.buffer.on_object != [] and hd(lm.buffer.on_object) != 0 do
      %{
        @off_object
        | possible_matches: lm.possible_matches,
          num_steps: FeatureAtLocationBuffer.get_num_matching_steps(lm.buffer),
          location: FeatureAtLocationBuffer.current_location(lm.buffer) || [0, 0, 0],
          result: lm.detected_object,
          primary: lm.terminal_state,
          stepwise: lm.terminal_state
      }
      |> classify(lm)
    else
      @off_object
    end
  end

  # No hypothesis left is a no-match however the episode ended.
  defp classify(%{possible_matches: []} = performance, _lm),
    do: %{performance | primary: "no_match", stepwise: "no_match"}

  # A module told the object has no label cannot be scored against one.
  defp classify(performance, %{primary_target: "no_label"}),
    do: %{performance | primary: "no_label", stepwise: "no_label"}

  defp classify(%{primary: "match"} = performance, lm) do
    targets = Map.get(lm.graph_id_to_target, lm.detected_object, MapSet.new())

    primary =
      if lm.primary_target in targets do
        "correct"
      else
        "confused"
      end

    %{
      performance
      | primary: primary,
        stepwise: if(lm.stepwise_target_object in targets, do: "correct", else: "confused"),
        rotation_error: if(primary == "correct", do: recognition_rotation_error(lm))
    }
  end

  # A timeout keeps the hypotheses it had left as its result, which is what Monty
  # writes: a run that gave up is only interesting for what it was still
  # considering.
  defp classify(%{primary: "time_out"} = performance, _lm) do
    performance = %{performance | result: performance.possible_matches}

    if length(performance.possible_matches) == 1,
      do: %{performance | primary: "pose_time_out", stepwise: "pose_time_out"},
      else: performance
  end

  defp classify(performance, _lm), do: performance

  # `rotations_to_quats(symmetric_rotations, invert: true)` when the object has
  # symmetry — the poses are matrices of rotation to apply to the displacement,
  # so they are inverted — and the detected rotation otherwise.
  defp recognition_rotation_error(lm) do
    case lm.buffer.stats["symmetric_rotations"] do
      nil ->
        recognition_pose_error(lm.buffer.stats["detected_rotation_quat"], lm)

      rotations ->
        rotations
        |> Enum.map(&matrix_to_xyzw/1)
        |> then(&recognition_pose_error(&1, lm))
    end
  end

  # Both arms of Monty's pose error, in Monty's order and rounding: four decimals
  # of degrees, because that is what its CSV has always held.
  defp recognition_pose_error(nil, _lm), do: nil
  defp recognition_pose_error(_rotation, %{primary_target_rotation_quat: nil}), do: nil

  defp recognition_pose_error(rotations, lm) do
    case as_poses(rotations) do
      [] ->
        nil

      poses ->
        poses
        |> then(
          &compute_pose_error(&1, as_poses(lm.primary_target_rotation_quat) |> List.first(),
            degrees: true
          )
        )
        |> Float.round(4)
    end
  end

  # Monty stores a pose three ways, and a stats read meets all of them: a detected
  # rotation as an `xyzw` quaternion, a symmetry's poses as 3×3 rotation matrices,
  # and either of those as a list when a recognition has several equivalent poses.
  defp as_poses([]), do: []
  defp as_poses([first | _rest] = one_pose) when is_number(first), do: [from_xyzw(one_pose)]
  defp as_poses([first | _rest] = poses) when is_list(first), do: Enum.map(poses, &as_rotation/1)

  defp as_rotation([first | _rest] = quaternion) when is_number(first), do: from_xyzw(quaternion)
  defp as_rotation(matrix) when is_list(matrix), do: from_xyzw(matrix_to_xyzw(matrix))

  # Monty's quaternions are `xyzw` (scipy's `as_quat`), and this port's are
  # `wxyz`, so every pose met in a stats read is turned round once, here.
  defp from_xyzw([x, y, z, w]) do
    {:ok, rotation} = Rotation.from_quaternion({w, x, y, z})
    rotation
  end

  defp matrix_to_xyzw(matrix) do
    case Rotation.from_matrix(matrix) do
      {:ok, rotation} -> rotation |> Rotation.invert() |> Rotation.to_xyzw()
    end
  end

  defp individual_ts_performance(lm) do
    stats = lm.buffer.stats

    case stats["individual_ts_reached_at_step"] do
      nil ->
        %{step: nil, performance: "patch_off_object", rotation_error: nil}

      step ->
        %{
          step: step,
          performance: individual_ts_object_performance(stats["individual_ts_object"], lm),
          rotation_error:
            individual_ts_rotation_error(
              stats["symmetric_rotations_ts"],
              stats["individual_ts_rot"],
              lm
            )
        }
    end
  end

  defp individual_ts_object_performance(nil, _lm), do: "no_match"

  defp individual_ts_object_performance(object, lm) do
    if lm.primary_target in Map.get(lm.graph_id_to_target, object, MapSet.new()),
      do: "correct",
      else: "confused"
  end

  defp individual_ts_rotation_error(symmetric, individual, lm) do
    case symmetric || individual do
      nil -> nil
      rotation -> recognition_pose_error(rotation, lm)
    end
  end

  # A pose is seven numbers: where, how turned, and how big. Monty's
  # `detected_pose` is the buffer's own, and `nil` for a module that detected
  # nothing.
  defp detected_pose(%{detected_pose: [x, y, z, rx, ry, rz, scale]}),
    do: {[x, y, z], [rx, ry, rz], scale}

  defp detected_pose(_lm), do: {nil, nil, nil}

  # `relative_time`: the time each step took, which is the buffer's clock read
  # differentially. It is not stored back into the buffer the way Monty does,
  # because a buffer here is a value inside the module and a log read should not
  # change one — only the total is wanted.
  defp total_time(nil), do: 0

  defp total_time(times) do
    times
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.sum()
  end

  # `compute_unsupervised_stats`: whether the object was recognised, and by a
  # graph that was built from it — a question only the training run's record can
  # answer.
  defp unsupervised_stats(possible_matches, target, graph_to_target, target_to_graph) do
    object_is_known = Map.has_key?(target_to_graph, target)

    result = unsupervised_result(object_is_known, possible_matches, target, graph_to_target)

    %{
      "mean_objects_per_graph" => mean_length(Map.values(graph_to_target)),
      "mean_graphs_per_object" => mean_length(Map.values(target_to_graph)),
      "TFNP" => result,
      "possible_match_sources" => possible_match_sources(possible_matches, graph_to_target)
    }
  end

  defp unsupervised_result(true = _known, possible_matches, target, graph_to_target) do
    if Enum.any?(possible_matches, &(target in Map.get(graph_to_target, &1, MapSet.new()))),
      do: "target_in_possible_matches_(TP)",
      else: "target_not_matched_(FN)"
  end

  defp unsupervised_result(_unknown, possible_matches, target, graph_to_target) do
    if Enum.any?(possible_matches, &(target not in Map.get(graph_to_target, &1, MapSet.new()))),
      do: "unknown_object_in_possible_matches_(FP)",
      else: "unknown_object_not_matched_(TN)"
  end

  defp mean_length([]), do: 0.0
  defp mean_length(sets), do: Enum.sum(Enum.map(sets, &MapSet.size/1)) / length(sets)

  defp possible_match_sources(possible_matches, graph_to_target) do
    possible_matches
    |> Enum.flat_map(&MapSet.to_list(Map.get(graph_to_target, &1, MapSet.new())))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join("-")
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
