defmodule Monty.Frameworks.Models.TwoDSensorModule do
  @moduledoc """
  The sensor module that reads a 2-D model pressed onto a 3-D surface: Monty's
  `TwoDSensorModule`.

  A surface agent moves, and its patch sees a piece of that surface. This module
  asks a different question from `CameraSM`: where on a *flat* version of the
  surface is the sensor now, and which way does the edge under it run? The answer
  is a 2-D coordinate and, when there is an edge through the patch, a fully
  defined pose — which is what lets a learning module build a 2-D model of a logo
  on a mug.

  ## Unrolling the surface

  A step is measured in 3-D and then unrolled: the movement is projected onto the
  tangent plane at the surface normal and resolved along that plane's basis. Two
  corrections make the result the distance *along* the surface:

    * **The arc-length correction** — a chord in the tangent plane is shorter
      than the arc it subtends, so each component is enlarged by
      `SensorProcessing.arc_length_corrected_displacement/6`, using the surface's
      curvature in that direction and the curvature frame the sensor fitted
      *before* an edge replaced it.
    * **The transported frame** — the tangent basis is carried from step to step
      rather than recomputed from the current normal, so the model's axes do not
      jump when the surface turns. Without it, a step on a curved surface would
      arrive in slightly different coordinates every time and the model would
      smear.

  The first observation of an episode has no previous location, so it *defines*
  the origin: the sensor's world `x` and `y` become its 2-D coordinates with `z`
  set to zero. That is Monty's own assumption, and it is only right when the
  camera's image plane is aligned with world `xy` — a camera looking along `x`
  would need the `yz` plane instead.

  ## Edges define the pose

  A 2-D sensor's pose comes from edges, not from curvature: every percept has
  `pose_fully_defined` taken away, and the edge detector puts a frame back only
  when it finds an edge near the patch's centre. An edge that is *geometric* — a
  crease in the world rather than ink on a surface — does not count, because the
  module is looking for the ink. `edge_strength` and `coherence` are reported
  either way, as zero when there is no edge, so a learning module can tell "no
  edge" from "not measured".
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Frameworks.Models.SensorModules.DefaultMessageNoise
  alias Monty.Frameworks.Models.SensorModules.FeatureChangeFilter
  alias Monty.Frameworks.Models.SensorModules.NoMessageNoise
  alias Monty.Frameworks.Models.SensorModules.ObservationProcessor
  alias Monty.Frameworks.Models.SensorModules.PassthroughPerceptFilter
  alias Monty.Frameworks.Models.SensorModules.SnapshotTelemetry
  alias Monty.Frameworks.Utils.EdgeDetection
  alias Monty.Frameworks.Utils.EdgeDetection.EdgeDetector
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame
  alias Monty.Math
  alias Monty.Observations.SensorObservation

  @edge_features ["edge_strength", "coherence"]

  defstruct sensor_module_id: nil,
            features: [],
            save_raw_obs: false,
            edge_detector: nil,
            processor: nil,
            noise: nil,
            filter: nil,
            filter_memory: nil,
            telemetry: nil,
            pose: nil,
            processed_observations: [],
            previous_3d_location: nil,
            previous_2d_location: [0.0, 0.0],
            tangent_frame: nil

  @type t :: %__MODULE__{}

  @doc "The module a config asks for, as Monty's `__init__` reads its arguments."
  @spec from_config(map()) :: {:ok, t()} | {:error, term()}
  def from_config(%{} = config) do
    with {:ok, features} <- features(config) do
      {:ok, build(Map.get(config, "sensor_module_id", "sensor_module_0"), features, config)}
    end
  end

  # A config whose `features` is an unresolved `${constants…}` is not a list of
  # features, and guessing would produce a sensor reporting features it never
  # named.
  defp features(%{"features" => features}) when is_list(features), do: {:ok, features}
  defp features(config), do: {:error, {:unresolved_features, Map.get(config, "features")}}

  @doc """
  A module for one sensor.

  Options are Monty's: `:features` (required), `:save_raw_obs`,
  `:pc1_is_pc2_threshold`, `:is_surface_sm`, `:edge_detector`, `:noise_params` and
  `:delta_thresholds`. An `:edge_detector` is built when the features ask for
  edge strength or coherence and none was given — a module that asked for an edge
  and measured nothing would report zero forever.
  """
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(sensor_module_id, options) do
    build(sensor_module_id, Keyword.fetch!(options, :features), options)
  end

  defp build(sensor_module_id, features, options) do
    extract_edges? = Enum.any?(@edge_features, &(&1 in features))
    thresholds = value(options, :delta_thresholds, nil)

    %__MODULE__{
      sensor_module_id: sensor_module_id,
      features: features,
      save_raw_obs: value(options, :save_raw_obs, false),
      edge_detector: edge_detector(options, extract_edges?),
      processor:
        ObservationProcessor.new(
          features: features,
          sensor_module_id: sensor_module_id,
          is_surface_sm: value(options, :is_surface_sm, false),
          pc1_is_pc2_threshold: value(options, :pc1_is_pc2_threshold, 10.0)
        ),
      noise: noise(value(options, :noise_params, nil)),
      filter: filter(thresholds),
      filter_memory: filter_memory(thresholds),
      telemetry: SnapshotTelemetry.new()
    }
  end

  # A config map is string-keyed and options are atoms; one reader for both.
  defp value(options, _key, default) when is_struct(options), do: default

  defp value(options, key, default) when is_map(options) do
    Map.get(options, key, Map.get(options, Atom.to_string(key), default))
  end

  defp value(options, key, default), do: Keyword.get(options, key, default)

  # A detector is `{module, detector}`, the same shape `noise` and `filter` take,
  # so a test can hand the module a detector that answers what a case needs while
  # the run uses the real one.
  defp edge_detector(options, extract_edges?) do
    case as_detector(value(options, :edge_detector, nil)) do
      nil when extract_edges? -> {EdgeDetector, EdgeDetector.new()}
      detector -> detector
    end
  end

  defp as_detector(nil), do: nil
  defp as_detector({module, detector}) when is_atom(module), do: {module, detector}
  defp as_detector(%EdgeDetector{} = detector), do: {EdgeDetector, detector}

  defp as_detector(attributes) when is_map(attributes),
    do: {EdgeDetector, EdgeDetector.new(detector_options(attributes))}

  defp as_detector(attributes) when is_list(attributes),
    do: {EdgeDetector, EdgeDetector.new(attributes)}

  # A config writes the detector as a Hydra node with the class in `_target_`;
  # the rest of the keys are its parameters, spelled the way Monty's `__init__`
  # names them. The mapping is written out rather than derived, so a parameter
  # this port does not have is a named failure instead of a setting that is
  # quietly dropped.
  @detector_parameters %{
    "gaussian_sigma" => :gaussian_sigma,
    "kernel_size" => :kernel_size,
    "strength_threshold" => :strength_threshold,
    "coherence_threshold" => :coherence_threshold,
    "radius" => :radius,
    "sigma_r" => :sigma_r,
    "depth_edge_threshold" => :depth_edge_threshold,
    "max_center_offset" => :max_center_offset
  }

  defp detector_options(attributes) do
    for {key, value} <- attributes,
        not String.starts_with?(to_string(key), "_"),
        do: {Map.fetch!(@detector_parameters, to_string(key)), value}
  end

  defp noise(params) when params in [nil, %{}], do: {NoMessageNoise, NoMessageNoise.new()}
  defp noise(params), do: {DefaultMessageNoise, DefaultMessageNoise.new(params)}

  defp filter(nil), do: {PassthroughPerceptFilter, PassthroughPerceptFilter.new()}
  defp filter(thresholds) when map_size(thresholds) == 0, do: filter(nil)

  defp filter(thresholds),
    do: FeatureChangeFilter.new(thresholds) |> then(&{FeatureChangeFilter, elem(&1, 0)})

  defp filter_memory(nil), do: PassthroughPerceptFilter.reset(nil)
  defp filter_memory(thresholds) when map_size(thresholds) == 0, do: filter_memory(nil)

  defp filter_memory(thresholds),
    do: thresholds |> FeatureChangeFilter.new() |> elem(1)

  @doc """
  Where the sensor is, given where the agent is — Monty's `update_state`.

  The sensor's own position and rotation in the agent's frame, turned by the
  agent's rotation and added to its position.
  """
  @impl true
  @spec update_state(AgentState.t(), t()) :: t()
  def update_state(%AgentState{} = agent, %__MODULE__{} = sm),
    do: %__MODULE__{sm | pose: AgentState.sensor_pose(agent, sm.sensor_module_id)}

  @doc """
  Monty's `step`: one observation, turned into a percept with a 2-D location.

  The order is Monty's and each part depends on the one before: record the raw
  observation if asked, extract features, take the curvature pose away and give
  back an edge pose only if an edge defines one, add noise, advance the 2-D
  position, and only then let the percept filter decide whether this percept is
  new enough to send.
  """
  @impl true
  @spec step(SensorObservation.t(), boolean(), Monty.Context.t(), t()) ::
          {Message.t() | nil, t()}
  def step(observation, motor_only?, ctx, %__MODULE__{} = sm) do
    sm = if sm.save_raw_obs, do: record_snapshot(sm, observation), else: sm

    case ObservationProcessor.process(sm.processor, observation) do
      {:ok, percept} ->
        {percept, sm, curvature_pose, normal} =
          percept
          |> without_defined_pose()
          |> place_on_surface(observation, sm)

        percept =
          percept
          |> add_noise(sm, ctx)
          |> silence_if_motor_only(motor_only?)

        {percept, sm} = advance_2d(percept, curvature_pose, normal, sm)
        {percept, sm} = apply_filter(sm, percept)

        {percept, %{sm | processed_observations: [percept | sm.processed_observations]}}

      {:error, _no_point_cloud} ->
        {nil, sm}
    end
  end

  @doc "Everything recorded so far: the raw observations and every percept made."
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = sm) do
    sm.telemetry
    |> SnapshotTelemetry.state_dict()
    |> Map.put(:processed_observations, Enum.reverse(sm.processed_observations))
  end

  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = sm) do
    {module, _filter} = sm.filter

    %__MODULE__{
      sm
      | telemetry: SnapshotTelemetry.reset(sm.telemetry),
        filter_memory: module.reset(sm.filter_memory),
        processed_observations: [],
        previous_3d_location: nil,
        previous_2d_location: [0.0, 0.0],
        tangent_frame: nil
    }
  end

  @doc """
  Drops what was seen, keeping the delta filter's memory and the surface's frame.

  The frame is *not* thrown away: it is where the model's axes are, and a new
  object on the same surface is still measured in them.
  """
  @impl true
  @spec clear_buffers(t()) :: t()
  def clear_buffers(%__MODULE__{} = sm) do
    %__MODULE__{sm | telemetry: SnapshotTelemetry.reset(sm.telemetry), processed_observations: []}
  end

  # Monty's own comment: only edges define the pose of a 2-D sensor, so whatever
  # the curvature fit said is withdrawn before the edge detector may put a frame
  # back.
  defp without_defined_pose(percept) do
    %{
      percept
      | morphological_features:
          Map.put(percept.morphological_features, "pose_fully_defined", false)
    }
  end

  # The tangent frame follows the surface, and the frame an edge defines is
  # expressed in it. `curvature_pose` is the curvature frame as it was *before*
  # the edge replaced it — what the arc-length correction measures curvature with
  # — and `normal` is the true surface normal, not the edge's.
  defp place_on_surface(percept, observation, sm) do
    if percept.process_features_in_lm and Message.on_object?(percept) do
      {:ok, normal} = Message.surface_normal(percept)
      curvature_pose = Map.fetch!(percept.morphological_features, "pose_vectors")
      sm = update_tangent_frame(sm, normal)

      percept =
        if sm.edge_detector do
          extract_2d_edge(percept, observation, normal, sm)
        else
          percept
        end

      {percept, sm, curvature_pose, normal}
    else
      {percept, sm, nil, nil}
    end
  end

  # Monty mutates the frame in place; this port threads the module, because the
  # frame it moves is the module's.
  defp update_tangent_frame(%__MODULE__{tangent_frame: nil} = sm, normal) do
    %__MODULE__{sm | tangent_frame: TangentFrame.new(SpatialArithmetics.normalize(normal))}
  end

  defp update_tangent_frame(%__MODULE__{} = sm, normal) do
    %__MODULE__{
      sm
      | tangent_frame:
          TangentFrame.transport(sm.tangent_frame, SpatialArithmetics.normalize(normal))
    }
  end

  defp extract_2d_edge(percept, observation, normal, sm) do
    {module, detector} = sm.edge_detector
    edge = module.detect(detector, observation)

    # A geometric edge is the surface ending against the background, not the edge
    # of a logo, so it is not a pose.
    detected? = edge.has_edge and not (edge.strength != 0.0 and edge.is_geometric_edge)

    percept =
      percept
      |> put_edge_feature("edge_strength", edge.strength, detected?, sm)
      |> put_edge_feature("coherence", edge.coherence, detected?, sm)

    if detected? do
      pose_2d =
        EdgeDetection.angle_to_pose_2d(
          edge.angle,
          SensorObservation.cam_to_world(observation),
          normal,
          sm.tangent_frame
        )

      %{
        percept
        | morphological_features:
            percept.morphological_features
            |> Map.put("pose_vectors", pose_2d)
            |> Map.put("pose_fully_defined", true)
      }
    else
      percept
    end
  end

  # Monty writes these only when the config asked for them, and writes a zero
  # rather than nothing when there is no edge: a learning module that used to
  # match on an edge should see it weaken, not disappear.
  defp put_edge_feature(percept, name, value, detected?, %__MODULE__{} = sm) do
    if name in sm.features do
      %{
        percept
        | non_morphological_features:
            Map.put(percept.non_morphological_features, name, if(detected?, do: value, else: 0.0))
      }
    else
      percept
    end
  end

  defp add_noise(percept, %__MODULE__{noise: {module, noise}}, ctx),
    do: module.call(noise, percept, ctx.rng)

  defp silence_if_motor_only(percept, true), do: %{percept | pass_message: false}
  defp silence_if_motor_only(percept, false), do: percept

  defp apply_filter(%__MODULE__{filter: {module, filter}} = sm, percept) do
    {percept, filter_memory} = module.call(filter, percept, sm.filter_memory)
    {percept, %{sm | filter_memory: filter_memory}}
  end

  # -- the 2-D position ------------------------------------------------------

  # Not on the object: no step to measure, and the origin stays where the sensor
  # last had one.
  defp advance_2d(percept, curvature_pose, normal, %__MODULE__{} = sm) do
    if Message.on_object?(percept) do
      advance_on_surface(percept, curvature_pose, normal, sm)
    else
      {%{percept | displacement: [0.0, 0.0, 0.0]}, sm}
    end
  end

  # The first observation of an episode is the origin of the 2-D model: world
  # `x` and `y`, with `z` set to zero because the camera is taken to be aligned
  # with the world's `xy` plane. A step with no normal has nothing to project
  # onto, so it is treated the same way.
  defp advance_on_surface(percept, _curvature_pose, nil, %__MODULE__{} = sm),
    do: flatten_to_2d(percept, percept.location, sm, percept.location)

  defp advance_on_surface(
         %{location: current} = percept,
         _curvature_pose,
         _normal,
         %__MODULE__{previous_3d_location: nil} = sm
       ),
       do: flatten_to_2d(percept, current, sm, current)

  defp advance_on_surface(percept, curvature_pose, normal, %__MODULE__{} = sm) do
    current = percept.location
    movement = SpatialArithmetics.subtract(current, sm.previous_3d_location)
    in_plane = SpatialArithmetics.project_onto_tangent_plane(movement, normal)

    if SpatialArithmetics.magnitude(in_plane) < Math.default_tolerance() do
      held = sm.previous_2d_location
      sm = %__MODULE__{sm | previous_3d_location: current}

      {%{percept | displacement: [0.0, 0.0, 0.0], location: held ++ [0.0]}, sm}
    else
      step_across(percept, in_plane, curvature_pose, sm, current)
    end
  end

  defp step_across(percept, in_plane, curvature_pose, %__MODULE__{} = sm, current) do
    basis_u = TangentFrame.basis_u(sm.tangent_frame)
    basis_v = TangentFrame.basis_v(sm.tangent_frame)

    {du, dv} =
      {
        SpatialArithmetics.dot(in_plane, basis_u),
        SpatialArithmetics.dot(in_plane, basis_v)
      }
      |> corrected_for_curvature(percept, curvature_pose, sm)

    position = add(sm.previous_2d_location, [du, dv])

    sm = %__MODULE__{sm | previous_2d_location: position, previous_3d_location: current}

    {%{percept | displacement: [du, dv, 0.0], location: position ++ [0.0]}, sm}
  end

  # The correction needs both halves: the curvature values the sensor reported,
  # and the frame they were measured in. Without either, the chord is what the
  # model gets — which is what Monty does too.
  defp corrected_for_curvature({du, dv}, percept, curvature_pose, %__MODULE__{} = sm) do
    with {:ok, principal_curvatures} <- Message.feature(percept, "principal_curvatures"),
         true <- is_list(principal_curvatures),
         %{} = pose_3d <- curvature_pose do
      SensorProcessing.arc_length_corrected_displacement(
        du,
        dv,
        TangentFrame.basis_u(sm.tangent_frame),
        TangentFrame.basis_v(sm.tangent_frame),
        principal_curvatures,
        pose_3d
      )
    else
      _nothing_to_correct_with -> {du, dv}
    end
  end

  defp flatten_to_2d(percept, location, %__MODULE__{} = sm, previous_3d) do
    [x, y | _rest] = location
    sm = %__MODULE__{sm | previous_3d_location: previous_3d, previous_2d_location: [x, y]}
    {%{percept | location: [x, y, 0.0]}, sm}
  end

  defp add(first, second) do
    first
    |> Enum.zip(second)
    |> Enum.map(fn {a, b} -> a + b end)
  end

  defp record_snapshot(%__MODULE__{pose: nil} = sm, _observation) do
    raise ArgumentError,
          "#{inspect(sm.sensor_module_id)} was asked to save its raw observations but has " <>
            "never been told where it is; call update_state/2 with the agent's state first"
  end

  defp record_snapshot(%__MODULE__{pose: pose} = sm, observation) do
    %__MODULE__{
      sm
      | telemetry:
          SnapshotTelemetry.raw_observation(
            sm.telemetry,
            observation,
            pose.rotation,
            pose.position
          )
    }
  end
end
