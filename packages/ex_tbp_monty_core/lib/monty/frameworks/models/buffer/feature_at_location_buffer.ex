defmodule Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer do
  @moduledoc """
  Features at locations arriving into one learning module, and the statistics of
  an episode.

  Mirrors `tbp/monty/frameworks/models/buffer.py::FeatureAtLocationBuffer`, with
  the one difference a functional language forces: the buffer is a value. Every
  method that mutates in Python returns a new buffer here, so a step reads as a
  pipeline rather than as a side effect, and a test can hold two versions of the
  same buffer and compare them.

  Two shapes need saying out loud, because numpy does them implicitly in Python:

    * **Rows** are plain lists in step order, newest last. `locations` is a list
      of `[x, y, z]` in metres; `features[channel][attr]` is a list of flat rows,
      with `pose_vectors` a 3×3 matrix flattened to nine numbers exactly as
      Monty flattens it before storing.
    * **NaN padding is `nil`.** Monty pads a channel that sent nothing at a step
      with NaN so that an index means the same step in every channel, then drops
      those rows with `np.isnan` when it builds a graph. `nil` is that padding
      here: `pad_to_target_length/3` writes it, `get_all_features_on_object/1`
      keeps it, and anything reading a row must expect it.

  Monty's own tests reach into `_pad_to_target_length`, so it is public here:
  index alignment is the behaviour this module exists to guarantee, and a test
  that cannot name it can only guess at it.
  """

  require Logger

  alias Monty.Cmp
  alias Monty.Cmp.Message
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, SurfacePoseVectors}

  @empty_stats %{
    "detected_path" => nil,
    "detected_location_on_model" => [nil, nil, nil],
    "detected_location_rel_body" => [nil, nil, nil],
    "detected_rotation" => nil,
    "detected_rotation_quat" => nil,
    "detected_scale" => nil,
    "symmetric_rotations" => nil,
    "symmetric_locations" => nil,
    "individual_ts_reached_at_step" => nil,
    "individual_ts_object" => nil,
    "individual_ts_pose" => nil,
    "symmetric_rotations_ts" => nil,
    "time" => [],
    "lm_processed_steps" => [],
    "matching_step_when_output_goal_set" => [],
    "goal_state_achieved" => [],
    "mlh_prediction_error" => []
  }

  defstruct locations: [],
            features: %{},
            on_object: [],
            input_percepts: [],
            last_location: nil,
            displacements: %{},
            channel_sender_types: %{},
            stats: @empty_stats,
            start_time: nil

  @type row :: [float()] | nil
  @type channel_features :: %{optional(String.t()) => [row()]}

  @type t :: %__MODULE__{
          locations: [[float()]],
          features: %{optional(String.t()) => channel_features()},
          on_object: [boolean()],
          input_percepts: [Message.t()],
          last_location: [float()] | nil,
          displacements: %{optional(String.t()) => [row()]},
          channel_sender_types: %{optional(String.t()) => :sm | :lm},
          stats: %{optional(String.t()) => term()},
          start_time: integer() | nil
        }

  @doc """
  A buffer with nothing in it yet.

  The clock starts when the buffer does: the `"time"` statistic is
  elapsed-since-episode-start, not a timestamp.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{stats: @empty_stats, start_time: System.monotonic_time(:microsecond)}

  @doc "Empties the buffer, as Monty's `reset` does."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()

  @doc "How many observations the buffer holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{on_object: on_object}), do: length(on_object)

  @doc """
  The features observed at one step, by channel.

  Mirrors `__getitem__`. A step a channel did not reach reads as `nil` rows,
  because that is what the padding says about it.
  """
  @spec at(t(), integer()) :: %{optional(String.t()) => %{optional(String.t()) => row()}}
  def at(%__MODULE__{features: features}, index) do
    Map.new(features, fn {channel, attrs} ->
      {channel, Map.new(attrs, fn {attr, rows} -> {attr, Enum.at(rows, index)} end)}
    end)
  end

  @doc """
  Adds one step's percepts.

  A step is the percepts that arrived together: its location is the mean of the
  sensor-module percepts (a learning module reports hypotheses, not places), and
  every percept teaches the buffer what kind of sender its channel is. A percept
  that does not carry features for the learning module — a view finder, a
  location-only report — contributes its location and nothing else, so its
  channel gets no feature rows at all.

  `{:error, :no_sensor_module_location}` for a step with no sensor module
  percept that has a location: Monty asserts on it, and a step with no place in
  it cannot be indexed against the rest of the episode.
  """
  @spec append(t(), [Message.t()]) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = buffer, percepts) do
    sensor_module_percepts = Enum.filter(percepts, &Message.from_sensor_module?/1)

    case Cmp.location_mean(sensor_module_percepts) do
      nil ->
        {:error, :no_sensor_module_location}

      location ->
        {buffer, any_on_object} = Enum.reduce(percepts, {buffer, false}, &add_percept/2)

        buffer =
          buffer
          |> Map.update!(:locations, &(&1 ++ [location]))
          |> store_displacement(sensor_module_percepts)
          |> Map.merge(%{
            last_location: location,
            on_object: buffer.on_object ++ [any_on_object]
          })

        {:ok, buffer}
    end
  end

  defp add_percept(%Message{} = percept, {buffer, any_on_object}) do
    channel = percept.sender_id

    buffer = %{
      buffer
      | channel_sender_types: Map.put(buffer.channel_sender_types, channel, percept.sender_type),
        features: Map.put_new(buffer.features, channel, %{})
    }

    buffer =
      if percept.process_features_in_lm, do: store_features(buffer, percept), else: buffer

    {buffer, any_on_object or Message.on_object?(percept)}
  end

  defp store_features(buffer, percept) do
    features =
      percept.morphological_features
      |> Enum.concat(Enum.to_list(percept.non_morphological_features))

    buffer =
      Enum.reduce(features, buffer, fn {attr, value}, buffer ->
        add_attr_to_feature_buffer(buffer, percept.sender_id, attr, value)
      end)

    add_attr_to_feature_buffer(
      buffer,
      percept.sender_id,
      "on_object",
      Message.on_object?(percept)
    )
  end

  @doc "Remembers a percept the buffer's learning module was given."
  @spec append_input_percepts(t(), Message.t()) :: t()
  def append_input_percepts(%__MODULE__{} = buffer, %Message{} = percept) do
    %{buffer | input_percepts: buffer.input_percepts ++ [percept]}
  end

  @doc """
  Records statistics for a step.

  Options mirror Monty's keyword arguments: `:update_time` appends the elapsed
  time, `:append` adds a row to an existing statistic rather than replacing it,
  and `:init_list` starts a new list for a statistic seen for the first time. A
  statistic the buffer has never held is added either way: statistics are a log,
  and a module that invents one is doing something Monty's own modules do.
  """
  @spec update_stats(t(), map(), keyword()) :: t()
  def update_stats(%__MODULE__{} = buffer, stats, opts \\ []) do
    append? = Keyword.get(opts, :append, true)
    init_list? = Keyword.get(opts, :init_list, true)

    stats_map = Enum.reduce(stats, buffer.stats, &put_stat(&1, &2, append?, init_list?))

    buffer = %{buffer | stats: stats_map}

    if Keyword.get(opts, :update_time, true) do
      %{buffer | stats: Map.update!(stats_map, "time", &(&1 ++ [elapsed(buffer)]))}
    else
      buffer
    end
  end

  defp put_stat({stat, value}, stats, true = _append?, _init_list?)
       when is_map_key(stats, stat) do
    Map.update!(stats, stat, &(List.wrap(&1) ++ [value]))
  end

  defp put_stat({stat, value}, stats, _append?, true = _init_list?) do
    Map.put(stats, stat, [value])
  end

  defp put_stat({stat, value}, stats, _append?, _init_list?) do
    Map.put(stats, stat, value)
  end

  @doc "Adds end-of-episode statistics, which replace rather than accumulate."
  @spec add_overall_stats(t(), map()) :: t()
  def add_overall_stats(%__MODULE__{} = buffer, stats) do
    update_stats(buffer, stats, update_time: false, append: false, init_list: false)
  end

  @doc "Overwrites the last entry of the named statistics (after voting, say)."
  @spec update_last_stats_entry(t(), map()) :: t()
  def update_last_stats_entry(%__MODULE__{} = buffer, stats) do
    stats =
      Enum.reduce(stats, buffer.stats, fn {stat, value}, stats ->
        case Map.get(stats, stat) do
          [_ | _] = entries -> Map.put(stats, stat, Enum.drop(entries, -1) ++ [value])
          _absent_or_empty -> stats
        end
      end)

    %{buffer | stats: stats}
  end

  @doc "The most recent location, or `nil` for an empty buffer."
  @spec current_location(t()) :: [float()] | nil
  def current_location(%__MODULE__{locations: []}), do: nil
  def current_location(%__MODULE__{locations: locations}), do: List.last(locations)

  @doc """
  The currently sensed location and orientation, as four rows: the location,
  then the channel's pose matrix.

  `"first"` means the first sensory input channel. A channel that sent no
  features at this step keeps the pose from the step it did send one, so the
  location and the orientation can come from different steps; Monty warns when
  that happens and so does this, because the combination is a quietly wrong pose
  rather than an error.
  """
  @spec get_current_pose(t(), String.t()) :: {:ok, [[float()]]} | {:error, term()}
  def get_current_pose(%__MODULE__{} = buffer, input_channel \\ "first") do
    with {:ok, channel} <- resolve_channel(buffer, input_channel),
         {:ok, rows} <- channel_pose_rows(buffer, channel),
         {:ok, location} <- fetch_location(buffer) do
      warn_if_stale(buffer, channel, rows)
      {:ok, [location | reshape_3x3(List.last(rows))]}
    end
  end

  defp resolve_channel(buffer, "first"), do: get_first_sensory_input_channel(buffer)

  defp resolve_channel(%__MODULE__{features: features}, channel) do
    if Map.has_key?(features, channel),
      do: {:ok, channel},
      else: {:error, {:no_such_channel, channel}}
  end

  defp channel_pose_rows(%__MODULE__{features: features}, channel) do
    case get_in(features, [channel, "pose_vectors"]) do
      nil -> {:error, {:no_pose_vectors, channel}}
      rows -> {:ok, rows}
    end
  end

  defp fetch_location(buffer) do
    case current_location(buffer) do
      nil -> {:error, :empty_buffer}
      location -> {:ok, location}
    end
  end

  defp warn_if_stale(buffer, channel, rows) do
    if length(rows) < length(buffer.locations) do
      Logger.warning(
        "Pose vectors of input channel '#{channel}' were last received at step " <>
          "#{length(rows) - 1}, but the current step is #{length(buffer.locations) - 1}. " <>
          "The returned pose combines a location and a pose observed at different time steps."
      )
    end

    :ok
  end

  defp reshape_3x3(flat) when is_list(flat) and length(flat) == 9 do
    flat |> Enum.chunk_every(3) |> Enum.map(fn row -> Enum.map(row, &(&1 || 0.0)) end)
  end

  # A channel with no pose vectors at all has no orientation to report; the
  # identity is the honest placeholder and the warning above has already said so.
  defp reshape_3x3(_missing), do: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

  @doc "Whether the last sensation was processed by the learning module."
  @spec get_last_obs_processed(t()) :: boolean()
  def get_last_obs_processed(%__MODULE__{stats: stats}) do
    stats |> Map.get("lm_processed_steps", []) |> List.last() == true
  end

  @doc """
  Whether the last sensation was on the object.

  Monty's message carries a boolean, and a recorded one may carry the same fact
  as `1.0`/`0.0` — so the answer is the truth of what was stored rather than the
  stored value itself, which callers then combine with `and`.
  """
  @spec get_currently_on_object(t()) :: boolean()
  def get_currently_on_object(%__MODULE__{on_object: []}), do: false

  def get_currently_on_object(%__MODULE__{on_object: on_object}),
    do: List.last(on_object) not in [false, nil, 0, 0.0]

  @doc "Every location from the steps where at least one input was on the object."
  @spec get_all_locations_on_object(t()) :: [[float()]]
  def get_all_locations_on_object(%__MODULE__{} = buffer) do
    buffer
    |> on_object_indices()
    |> Enum.map(&Enum.at(buffer.locations, &1))
  end

  @doc "Every percept the buffer's learning module has been given."
  @spec get_all_input_percepts(t()) :: [Message.t()]
  def get_all_input_percepts(%__MODULE__{input_percepts: percepts}), do: percepts

  @doc "The percept before the last one, or `nil`."
  @spec get_previous_input_percepts(t()) :: Message.t() | nil
  def get_previous_input_percepts(%__MODULE__{input_percepts: percepts})
      when length(percepts) > 1,
      do: Enum.at(percepts, -2)

  def get_previous_input_percepts(%__MODULE__{}), do: nil

  @doc "The nth displacement (negative counts from the end, as Monty uses it)."
  @spec nth_displacement(t(), integer()) :: [float()] | nil
  def nth_displacement(%__MODULE__{displacements: displacements}, n) do
    displacements |> Map.get("displacement", []) |> Enum.at(n)
  end

  @doc "The most recent displacement."
  @spec current_displacement(t()) :: [float()] | nil
  def current_displacement(%__MODULE__{} = buffer), do: nth_displacement(buffer, -1)

  @doc "The most recent point-pair feature."
  @spec current_ppf(t()) :: [float()] | nil
  def current_ppf(%__MODULE__{displacements: displacements}) do
    displacements |> Map.get("ppf", []) |> List.last()
  end

  @doc """
  The length of the first observed displacement, for scale in a displacement
  learning module: the ppf's first element when there is one, otherwise the norm
  of the first displacement.

  Monty reads row 1, not row 0: the first step has no displacement to measure.
  """
  @spec first_displacement_len(t()) :: float() | nil
  def first_displacement_len(%__MODULE__{displacements: displacements}) do
    case displacements do
      %{"ppf" => [_first, [length | _rest] | _more]} ->
        length

      %{"ppf" => [_only]} ->
        nil

      %{"displacement" => rows} ->
        rows |> Enum.at(1) |> norm()

      _neither ->
        nil
    end
  end

  defp norm(nil), do: nil
  defp norm(vector), do: vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

  @doc """
  Every observed feature that was on the object, by channel and feature.

  Each channel is padded to the episode's length first — a channel that stopped
  sending keeps its index — and then read at the steps where *any* input was on
  the object. A row the channel did not send at such a step stays `nil`, which is
  what Monty's NaN means here.
  """
  @spec get_all_features_on_object(t()) :: %{optional(String.t()) => channel_features()}
  def get_all_features_on_object(%__MODULE__{} = buffer) do
    indices = on_object_indices(buffer)

    Map.new(buffer.features, fn {channel, attrs} ->
      {channel,
       Map.new(attrs, fn {attr, rows} ->
         padded = pad_to_target_length(buffer, rows)
         {attr, Enum.map(indices, &Enum.at(padded, &1))}
       end)}
    end)
  end

  defp on_object_indices(%__MODULE__{on_object: on_object}) do
    on_object
    |> Enum.with_index()
    |> Enum.filter(fn {on_object, _index} -> on_object end)
    |> Enum.map(fn {_on_object, index} -> index end)
  end

  @doc "The number of steps recorded."
  @spec get_num_observations_on_object(t()) :: non_neg_integer()
  def get_num_observations_on_object(%__MODULE__{} = buffer), do: size(buffer)

  @doc "How many steps the learning module processed (exploration steps included)."
  @spec get_num_matching_steps(t()) :: non_neg_integer()
  def get_num_matching_steps(%__MODULE__{stats: stats}) do
    stats |> Map.get("lm_processed_steps", []) |> Enum.count(&(&1 == true))
  end

  @doc "How many goals the learning module's goal generator has produced."
  @spec get_num_goals_generated(t()) :: non_neg_integer()
  def get_num_goals_generated(%__MODULE__{stats: stats}) do
    stats |> Map.get("goal_state_achieved", []) |> length()
  end

  @doc "The matching step at which the last goal was generated."
  @spec get_matching_step_when_output_goal_set(t()) :: integer() | nil
  def get_matching_step_when_output_goal_set(%__MODULE__{stats: stats}) do
    stats |> Map.get("matching_step_when_output_goal_set", []) |> List.last()
  end

  @doc """
  How many matching steps have elapsed since the last output goal: all of them
  when there has never been one.
  """
  @spec get_num_steps_post_output_goal_generated(t()) :: integer()
  def get_num_steps_post_output_goal_generated(%__MODULE__{} = buffer) do
    matching_steps = get_num_matching_steps(buffer)

    if get_num_goals_generated(buffer) == 0 do
      matching_steps
    else
      matching_steps - (get_matching_step_when_output_goal_set(buffer) || 0)
    end
  end

  @doc "Everything a graph update needs from the buffer."
  @spec get_infos_for_graph_update(t()) :: map()
  def get_infos_for_graph_update(%__MODULE__{} = buffer) do
    %{
      locations: get_all_locations_on_object(buffer),
      features: get_all_features_on_object(buffer),
      object_location_rel_body: buffer.stats["detected_location_rel_body"],
      location_rel_model: buffer.stats["detected_location_on_model"]
    }
  end

  @doc """
  The name of the first channel that is a sensor module.

  `{:error, {:no_sensory_channel, types}}` when there are channels but none is a
  sensor module — a learning module fed only by a view finder or by lateral
  votes has nothing of its own to sense with, which Monty raises on too.
  """
  @spec get_first_sensory_input_channel(t()) :: {:ok, String.t()} | {:error, term()}
  def get_first_sensory_input_channel(%__MODULE__{channel_sender_types: types})
      when map_size(types) == 0,
      do: {:error, :no_channels}

  def get_first_sensory_input_channel(%__MODULE__{channel_sender_types: types}) do
    case Enum.find(Enum.sort(Map.keys(types)), &(types[&1] == :sm)) do
      nil -> {:error, {:no_sensory_channel, types}}
      channel -> {:ok, channel}
    end
  end

  @doc """
  Records the terminal state of an individual learning module.

  Only the first time the terminal condition is met is kept: an episode ends
  once, and the first ending is the one that mattered.
  """
  @spec set_individual_ts(t(), term(), term()) :: t()
  def set_individual_ts(%__MODULE__{stats: stats} = buffer, object_id, pose) do
    if Map.get(stats, "individual_ts_reached_at_step") do
      buffer
    else
      stats =
        stats
        |> Map.put("individual_ts_reached_at_step", get_num_matching_steps(buffer))
        |> Map.put("individual_ts_object", object_id)
        |> Map.put("individual_ts_pose", pose)
        |> Map.put("individual_ts_rot", stats["detected_rotation_quat"])
        |> Map.put("symmetric_rotations_ts", stats["symmetric_rotations"])

      %{buffer | stats: stats}
    end
  end

  # -- filling the buffer ----------------------------------------------------

  defp store_displacement(buffer, sensor_module_percepts) do
    displacement =
      sensor_module_percepts
      |> Enum.find(%{}, &(&1.displacement not in [nil, %{}]))
      |> Map.get(:displacement, %{})

    Enum.reduce(displacement, buffer, fn {name, value}, buffer ->
      add_displacement(buffer, name, List.wrap(value))
    end)
  end

  defp add_displacement(buffer, name, value) do
    width = length(value)
    rows = buffer.displacements |> Map.get(name, []) |> pad(size(buffer) + 1, width)

    %{buffer | displacements: Map.put(buffer.displacements, name, replace_last(rows, value))}
  end

  defp add_attr_to_feature_buffer(buffer, channel, attr, value) do
    row = flatten_value(value)

    rows =
      buffer.features
      |> get_in([channel, attr])
      |> Kernel.||([])
      |> pad(size(buffer) + 1, length(row))

    attrs = buffer.features |> Map.fetch!(channel) |> Map.put(attr, replace_last(rows, row))

    %{buffer | features: Map.put(buffer.features, channel, attrs)}
  end

  # A scalar is a one-element row so that every feature has a width. Booleans
  # become 1.0/0.0 because that is what Monty's numeric arrays store.
  defp flatten_value(value) when is_boolean(value), do: [if(value, do: 1.0, else: 0.0)]
  defp flatten_value(value) when is_number(value), do: [value * 1.0]
  defp flatten_value(value) when is_list(value), do: List.flatten(value)

  defp flatten_value(%SurfacePoseVectors{value: value}), do: List.flatten(value)
  defp flatten_value(%OrientationMatrix{value: value}), do: List.flatten(value)
  defp flatten_value(%GazeDirection{value: value}), do: List.flatten(value)
  defp flatten_value(nil), do: [nil]

  defp replace_last([], value), do: [value]
  defp replace_last(rows, value), do: Enum.drop(rows, -1) ++ [value]

  @doc """
  Pads rows to `target_length` with `nil`, keeping the data at the beginning.

  `:target_length` defaults to the buffer's length; `:width` defaults to the
  width the existing rows already have. A caller adding the first row of a new
  feature must say how wide it is, because an empty list has no width to read.
  Monty raises `ValueError` for the same two mistakes and so does this: a row of
  the wrong width silently shifts every feature of a step.
  """
  @spec pad_to_target_length(t(), [row()], keyword()) :: [row()]
  def pad_to_target_length(%__MODULE__{} = buffer, rows, opts \\ []) do
    target_length = Keyword.get(opts, :target_length) || size(buffer)
    width = Keyword.get(opts, :width) || row_width(rows)

    cond do
      is_nil(width) ->
        raise ArgumentError, "cannot infer a row width from an empty buffer; pass :width"

      rows_width(rows) not in [nil, width] ->
        raise ArgumentError,
              "column dimension mismatch: rows are #{rows_width(rows)} wide but #{width} " <>
                "was asked for; padding along the column dimension is not allowed"

      length(rows) >= target_length ->
        rows

      true ->
        rows ++ List.duplicate(List.duplicate(nil, width), target_length - length(rows))
    end
  end

  defp pad(rows, target_length, width) do
    pad_to_target_length(%__MODULE__{}, rows, target_length: target_length, width: width)
  end

  defp row_width([]), do: nil
  defp row_width([nil | _rest]), do: nil
  defp row_width([row | _rest]) when is_list(row), do: length(row)

  defp rows_width(rows) do
    rows
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&length/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [width] -> width
      _several -> :mixed
    end
  end

  defp elapsed(%__MODULE__{start_time: start_time}) when is_integer(start_time),
    do: (System.monotonic_time(:microsecond) - start_time) / 1_000_000
end
