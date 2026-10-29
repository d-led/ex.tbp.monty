defmodule Monty.Frameworks.Environments.PositioningProcedures.GetGoodView do
  @moduledoc """
  Puts the agent somewhere it can see the object before the episode starts.

  Mirrors
  `tbp/monty/frameworks/environments/positioning_procedures.py::GetGoodView`, the
  procedure every distant-agent evaluation episode starts with. Two things have
  to be true before the first percept is worth anything: the object has to fill
  enough of the view (or be close enough), and the sensor's centre pixel has to
  be on it. So the procedure is a small state machine:

    1. in a scene with several objects, first turn towards the target, because
       the agent may start looking at the wrong thing;
    2. translate towards the object until it fills `good_view_percentage` of the
       view or its nearest point is within `good_view_distance`;
    3. turn the sensor onto the object — no more than
       `max_orientation_attempts` times, after which the procedure gives up and
       says `truncated`, and the episode starts wherever the agent happens to be.

  ## Why it is not a motor policy

  It runs against the environment directly, before the motor system exists in the
  step, and it moves the camera by aiming at a *pixel* it found: the location to
  look at is the brightest point of a smoothed on-object mask, which needs no
  hypothesis and no memory.

  ## The smoothing

  Monty smooths the on-object mask with `scipy.ndimage.gaussian_filter(image,
  size // 16, mode="constant")` before taking its maximum, so that a single stray
  on-object pixel does not attract the gaze. That is a *different* Gaussian from
  the one the salience code uses (`cv2.GaussianBlur`, truncate `8σ+1`,
  reflect-101): scipy truncates at `4σ`, pads with zeros, and takes `sigma` in
  pixels. The rule below was measured against scipy's own answer to `2e-16`
  rather than recalled — see `docs/monty-bugs.md` §1.15.

  ## State

  Monty's procedure mutates itself; this one is a value, so a step answers
  `{result, procedure}` and the caller keeps what it gets back.
  """

  @behaviour Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedure

  alias Monty.Frameworks.Actions.{LookDown, MoveForward, TurnLeft}
  alias Monty.Frameworks.Environments.PositioningProcedures
  alias Monty.Frameworks.Environments.PositioningProcedures.ObjectNotVisibleError
  alias Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedureResult
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  # Monty's module constants, which the factory defaults to.
  @good_view_distance_default 0.03
  @good_view_percentage_default 0.5

  # scipy's `gaussian_filter` truncates the kernel at four sigma and pads with
  # zeros; `cv2.GaussianBlur` does neither (`docs/monty-bugs.md` §1.15).
  @truncate 4.0

  @enforce_keys [:agent_id, :sensor_id, :target_semantic_id]
  defstruct agent_id: nil,
            sensor_id: nil,
            target_semantic_id: nil,
            good_view_distance: @good_view_distance_default,
            good_view_percentage: @good_view_percentage_default,
            multiple_objects_present: false,
            allow_translation: true,
            max_orientation_attempts: 1,
            num_orientation_attempts: 0,
            executed_multiple_objects_orientation: false

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sensor_id: atom() | String.t(),
          target_semantic_id: integer(),
          good_view_distance: float(),
          good_view_percentage: float(),
          multiple_objects_present: boolean(),
          allow_translation: boolean(),
          max_orientation_attempts: integer(),
          num_orientation_attempts: integer(),
          executed_multiple_objects_orientation: boolean()
        }

  @doc "A procedure for the device `:agent_id` sees through, and the object to look at."
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sensor_id: Keyword.fetch!(options, :sensor_id),
      target_semantic_id: Keyword.fetch!(options, :target_semantic_id),
      good_view_distance: Keyword.get(options, :good_view_distance, @good_view_distance_default),
      good_view_percentage:
        Keyword.get(options, :good_view_percentage, @good_view_percentage_default),
      multiple_objects_present: Keyword.get(options, :multiple_objects_present, false),
      allow_translation: Keyword.get(options, :allow_translation, true),
      max_orientation_attempts: Keyword.get(options, :max_orientation_attempts, 1)
    }
  end

  @doc "The distance Monty's factory uses when a config does not say otherwise."
  def good_view_distance_default, do: @good_view_distance_default

  @doc "The percentage Monty's factory uses when a config does not say otherwise."
  def good_view_percentage_default, do: @good_view_percentage_default

  @impl true
  def call(%__MODULE__{} = procedure, observation, state) do
    procedure
    |> orient_a_multi_object_scene(observation, state)
    |> case do
      {:done, result, procedure} -> {result, procedure}
      {:continue, procedure} -> translate_then_orient(procedure, observation, state)
    end
  end

  # A scene with several objects may start with the agent looking at one of the
  # others, which no amount of translation fixes. Monty visits this state once.
  defp orient_a_multi_object_scene(procedure, observation, state) do
    if procedure.multiple_objects_present and
         not procedure.executed_multiple_objects_orientation do
      procedure = %{procedure | executed_multiple_objects_orientation: true}

      if on_target_object?(procedure, observation) do
        {:continue, procedure}
      else
        {:done,
         %PositioningProcedureResult{actions: orient_to_object(procedure, observation, state)},
         procedure}
      end
    else
      {:continue, procedure}
    end
  end

  defp translate_then_orient(procedure, observation, state) do
    moving = if procedure.allow_translation, do: move_close_enough(procedure, observation)

    if moving != nil do
      {%PositioningProcedureResult{actions: [moving]}, procedure}
    else
      procedure = %{procedure | allow_translation: false}
      on_target = on_target_object?(procedure, observation)

      turn_or_finish(procedure, observation, state, on_target)
    end
  end

  defp turn_or_finish(procedure, observation, state, false) do
    if procedure.num_orientation_attempts < procedure.max_orientation_attempts do
      procedure = %{procedure | num_orientation_attempts: procedure.num_orientation_attempts + 1}

      {%PositioningProcedureResult{actions: orient_to_object(procedure, observation, state)},
       procedure}
    else
      # Out of attempts: the episode starts where the agent is, and the caller
      # can see from `truncated` that it is not where the procedure wanted.
      {%PositioningProcedureResult{truncated: true}, procedure}
    end
  end

  defp turn_or_finish(procedure, _observation, _state, true) do
    {%PositioningProcedureResult{success: true, terminated: true}, procedure}
  end

  @doc """
  The action that brings the object closer, or `nil` when it is close enough.

  Close enough means either that the object fills `good_view_percentage` of the
  view, or that its nearest visible point is within `good_view_distance` — the
  percentage for big objects, the distance for small ones, so that a small object
  is not driven past and a big one is not entered.

  In a scene with other objects it also refuses to step forward when another
  object is already a quarter of the way inside `good_view_distance`, which is
  how the agent avoids walking into the scenery on its way to the target.
  """
  @spec move_close_enough(t(), map()) :: MoveForward.t() | nil
  def move_close_enough(%__MODULE__{} = procedure, observation) do
    semantic = semantic_image(procedure, observation)
    depth = depth_image(procedure, observation)

    target_pixels = on_target_pixels(semantic, procedure.target_semantic_id)
    count = length(target_pixels)

    cond do
      procedure.multiple_objects_present and count == 0 ->
        # The target is not in this view at all; there is nowhere to move to.
        nil

      count == 0 ->
        raise ObjectNotVisibleError

      true ->
        move_or_stay(procedure, semantic, depth, target_pixels)
    end
  end

  defp move_or_stay(procedure, semantic, depth, target_pixels) do
    closest_on_target = target_pixels |> Enum.map(&depth_value(depth, &1)) |> Enum.min()

    percentage =
      PositioningProcedures.get_perc_on_obj_semantic(semantic, procedure.target_semantic_id)

    any_object_pixels = semantic |> List.flatten() |> Enum.map(&(&1 > 0))
    closest_on_any = closest_depth(depth, any_object_pixels)

    cond do
      percentage >= procedure.good_view_percentage ->
        nil

      closest_on_target <= procedure.good_view_distance ->
        nil

      procedure.multiple_objects_present and
          closest_on_any < procedure.good_view_distance / 4.0 ->
        nil

      true ->
        %MoveForward{agent_id: procedure.agent_id, distance: 0.01}
    end
  end

  # The target is visible whenever this is called, so at least one pixel is on
  # an object and there is always a nearest one.
  defp closest_depth(depth, mask) do
    depth
    |> List.flatten()
    |> Enum.zip(mask)
    |> Enum.filter(fn {_value, wanted?} -> wanted? end)
    |> Enum.map(fn {value, _wanted?} -> value end)
    |> Enum.min()
  end

  @doc """
  Whether the centre pixel of the view is on the target object.

  In a single-object scene every object pixel counts as the target, which is
  Monty's remapping: the scene has one object, so whatever is in view is it.
  """
  @spec on_target_object?(t(), map()) :: boolean()
  def on_target_object?(%__MODULE__{} = procedure, observation) do
    {rows, columns} = image_shape(procedure, observation)
    semantic = semantic_image(procedure, observation)
    centre = Enum.at(Enum.at(semantic, div(rows, 2)), div(columns, 2))

    centre == procedure.target_semantic_id
  end

  @doc """
  The two actions that aim the sensor at the target.

  The pixel to aim at is the maximum of the smoothed on-object mask, so the gaze
  goes to the middle of the visible surface rather than to its edge.
  """
  @spec orient_to_object(t(), map(), map()) :: [LookDown.t() | TurnLeft.t()]
  def orient_to_object(%__MODULE__{} = procedure, observation, state) do
    relative_location = find_location_to_look_at(procedure, observation, state)
    {down, left} = compute_look_amounts(procedure, relative_location, state)

    [
      %LookDown{agent_id: procedure.agent_id, rotation_degrees: down},
      %TurnLeft{agent_id: procedure.agent_id, rotation_degrees: left}
    ]
  end

  @doc """
  Where in the view to look, relative to the sensor: the middle of the target.

  The on-object mask is smoothed with sigma `rows // 16` before the brightest
  point is taken — a sixteenth of the view is the scale a patch of object has to
  be to matter — and the mask is multiplied back in so that the maximum cannot
  land where smoothing spread brightness into the background. The answer is
  relative to the sensor, because that is what the two rotations need.
  """
  @spec find_location_to_look_at(t(), map(), map()) :: [float()]
  def find_location_to_look_at(%__MODULE__{} = procedure, observation, state) do
    {rows, _columns} = image_shape(procedure, observation)
    semantic = semantic_image(procedure, observation)

    mask =
      Enum.map(semantic, fn row ->
        Enum.map(row, &if(&1 == procedure.target_semantic_id, do: 1.0, else: 0.0))
      end)

    smoothed = smooth(mask, div(rows, 16))
    {row, column} = brightest(smoothed, mask)

    location = location_at(procedure, observation, row, column)

    offset =
      SpatialArithmetics.add(sensor_position(state, procedure), agent_position(state, procedure))

    SpatialArithmetics.subtract(location, offset)
  end

  @doc """
  How far to look down and left to aim at a location relative to the sensor.

  The location is rotated back into the sensor's own frame first, so the answer
  is "relative to where this sensor already points". Looking up and turning right
  are negative amounts.
  """
  @spec compute_look_amounts(t(), [float()], map()) :: {float(), float()}
  def compute_look_amounts(%__MODULE__{} = procedure, relative_location, state) do
    rotation = Rotation.multiply(rotation_of(state, procedure), sensor_rotation(state, procedure))
    [x, y, z] = Rotation.apply(Rotation.invert(rotation), relative_location)

    left = -degrees(:math.atan2(x, -z))
    down = -degrees(:math.atan2(y, :math.sqrt(x * x + z * z)))

    {down, left}
  end

  # -- the observation, as grids ---------------------------------------------

  defp image_shape(procedure, observation) do
    depth = depth_image(procedure, observation)
    {length(depth), length(hd(depth))}
  end

  defp depth_image(%__MODULE__{} = procedure, observation),
    do:
      observation
      |> Map.fetch!(procedure.agent_id)
      |> Map.fetch!(procedure.sensor_id)
      |> Map.fetch!("depth")

  defp depth_value(depth, {row, column}),
    do: depth |> Enum.at(row) |> Enum.at(column)

  # The semantic ids arrive as a flat list of points, one row per pixel, and are
  # put back into the image they were read from — which is also where the
  # `multiple_objects_present: false` remapping happens: in a one-object scene
  # every object pixel is the target.
  defp semantic_image(%__MODULE__{} = procedure, observation) do
    columns = observation |> depth_image_of(procedure) |> hd() |> length()

    observation
    |> Map.fetch!(procedure.agent_id)
    |> Map.fetch!(procedure.sensor_id)
    |> Map.fetch!("semantic_3d")
    |> Enum.map(fn [_x, _y, _z, semantic_id] -> semantic_id_at(procedure, semantic_id) end)
    |> Enum.chunk_every(columns)
  end

  defp semantic_id_at(
         %__MODULE__{multiple_objects_present: false, target_semantic_id: target},
         id
       ),
       do: if(id > 0, do: target, else: 0)

  defp semantic_id_at(%__MODULE__{}, id), do: id

  defp on_target_pixels(semantic, target) do
    for {row, row_index} <- Enum.with_index(semantic),
        {id, column_index} <- Enum.with_index(row),
        id == target,
        do: {row_index, column_index}
  end

  # The location of a pixel, from the point cloud the observation carries.
  defp location_at(%__MODULE__{} = procedure, observation, row, column) do
    columns = observation |> depth_image_of(procedure) |> hd() |> length()

    observation
    |> Map.fetch!(procedure.agent_id)
    |> Map.fetch!(procedure.sensor_id)
    |> Map.fetch!("semantic_3d")
    |> Enum.at(row * columns + column)
    |> Enum.take(3)
  end

  defp depth_image_of(observation, %__MODULE__{} = procedure),
    do:
      observation
      |> Map.fetch!(procedure.agent_id)
      |> Map.fetch!(procedure.sensor_id)
      |> Map.fetch!("depth")

  defp sensor_position(state, %__MODULE__{} = procedure),
    do:
      state
      |> Map.fetch!(procedure.agent_id)
      |> Map.fetch!(:sensors)
      |> Map.fetch!(procedure.sensor_id)
      |> Map.fetch!(:position)

  defp agent_position(state, %__MODULE__{} = procedure),
    do: state |> Map.fetch!(procedure.agent_id) |> Map.fetch!(:position)

  defp rotation_of(state, %__MODULE__{} = procedure),
    do: state |> Map.fetch!(procedure.agent_id) |> Map.fetch!(:rotation)

  defp sensor_rotation(state, %__MODULE__{} = procedure),
    do:
      state
      |> Map.fetch!(procedure.agent_id)
      |> Map.fetch!(:sensors)
      |> Map.fetch!(procedure.sensor_id)
      |> Map.fetch!(:rotation)

  # -- smoothing, as scipy does it -------------------------------------------

  # `scipy.ndimage.gaussian_filter(image, sigma, mode="constant")`: a separable
  # Gaussian of radius `int(4 sigma + 0.5)`, normalised to one, applied with zero
  # padding. A sigma of zero smooths nothing, and neither does this.
  defp smooth(image, sigma) when sigma <= 0, do: image

  defp smooth(image, sigma) do
    weights = kernel(sigma)
    image |> convolve(weights, :row) |> convolve(weights, :column)
  end

  defp kernel(sigma) do
    radius = trunc(@truncate * sigma + 0.5)
    weights = for offset <- -radius..radius, do: :math.exp(-0.5 * :math.pow(offset / sigma, 2))
    total = Enum.sum(weights)
    Enum.map(weights, &(&1 / total))
  end

  defp convolve(image, weights, axis) do
    radius = div(length(weights) - 1, 2)

    if axis == :row do
      Enum.map(image, fn row -> correlate(row, weights, radius) end)
    else
      image
      |> transpose()
      |> Enum.map(fn row -> correlate(row, weights, radius) end)
      |> transpose()
    end
  end

  # Zero padding: `mode="constant"` in scipy means "outside the image is zero".
  defp correlate(values, weights, radius) do
    padded = List.duplicate(0.0, radius) ++ values ++ List.duplicate(0.0, radius)
    count = length(values)

    0..(count - 1)
    |> Enum.map(fn index ->
      padded
      |> Enum.slice(index, length(weights))
      |> Enum.zip(weights)
      |> Enum.map(fn {value, weight} -> value * weight end)
      |> Enum.sum()
    end)
  end

  defp transpose(image) do
    image
    |> Enum.zip_with(& &1)
  end

  # `np.argmax` answers the *first* maximum in row-major order, which matters
  # here: a symmetric object has a plateau of equally bright pixels, and picking
  # the last of them would aim the sensor at the wrong side of it.
  defp brightest(smoothed, mask) do
    smoothed
    |> Enum.zip(mask)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{smoothed_row, mask_row}, row} ->
      smoothed_row
      |> Enum.zip(mask_row)
      |> Enum.with_index()
      |> Enum.map(fn {{value, weight}, column} -> {value * weight, row, column} end)
    end)
    |> Enum.reduce(nil, fn {value, _row, _column} = candidate, best ->
      case best do
        nil -> candidate
        {best_value, _row, _column} when best_value < value -> candidate
        _first_maximum -> best
      end
    end)
    |> then(fn {_value, row, column} -> {row, column} end)
  end

  defp degrees(radians), do: radians * 180.0 / :math.pi()
end
