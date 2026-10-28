defmodule Monty.Frameworks.Models.MotorPolicies.SurfacePolicy do
  @moduledoc """
  A policy that walks the surface of an object, feeling along it.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::SurfacePolicy`, the
  policy a surface agent runs: it keeps the sensor a fixed distance from the
  surface and moves *along* it, so the evidence it collects comes from a band
  that crosses the object rather than from wherever a random walk lands.

  ## The cycle

  Four actions, in order, forever:

      MoveForward -> OrientHorizontal -> OrientVertical -> MoveTangentially

  Moving forward puts the sensor at `desired_object_distance` from what it sees;
  orienting horizontally turns the sensor to face the surface normal's sideways
  lean, orienting vertically its up-and-down lean, and moving tangentially takes
  a step along the surface in a direction that is mostly the last one and
  partly new (`alpha`, Monty's "0 is the same as before, 1 is a random walk").
  Only the vertical orienting step is worth showing the learning modules — the
  other three are bookkeeping to stay on the object — which is what
  `motor_only_step` says.

  ## When it cannot see the object

  `object_coverage` below a tenth, or a search already under way, means the
  sensor has left the object; then the policy searches: back off to a circle
  four times the desired distance in front of it and step round it thirty
  degrees at a time, horizontally for a full turn, then vertically for a
  second, then at random angles until something comes into view.

  ## What it shares with `InformedPolicy`

  Monty's `SurfacePolicy` is an `InformedPolicy`: it inherits the jump machinery
  and overrides the step. Here the jump step is
  `InformedPolicy.goal_driven_actions/4`, taken by any policy carrying the jump
  fields, and Monty's `_handle_successful_jump` hook is `handle_successful_jump/1`
  dispatched to the policy's own module (`docs/monty-bugs.md` §2.9). A jump that
  lands with the object in view restarts the cycle as if the agent had just
  moved tangentially, which is how a goal-driven step hands back to walking.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Cmp

  alias Monty.Frameworks.Actions.{
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical
  }

  alias Monty.Frameworks.Actions.ActionSamplers
  alias Monty.Frameworks.Actions.ActionSamplers.ActionSampler
  alias Monty.Frameworks.Models.MotorPolicies
  alias Monty.Frameworks.Models.MotorPolicies.{InformedPolicy, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorPolicies.SurfacePolicyTelemetry
  alias Monty.Geometry.Rotation

  # Monty hardcodes the view finder as the sensor it searches with.
  @view_finder "view_finder"

  # Under this much coverage of the view by the object, the sensor is not on it.
  @coverage_to_search 0.1

  # Inside a metre of the centre of the view: something is visible there.
  @visible_depth 1.0

  # A tenth of the view is enough to move at full length; below that the step
  # shrinks, so a sensor near an edge does not walk off it.
  @coverage_to_shorten 0.2
  @coverage_to_quarter 0.75

  # The search steps round a circle four times the desired distance away, thirty
  # degrees at a time: a full turn, then a full turn on the other axis, then
  # random angles.
  @search_circle_factor 4.0
  @search_step_degrees 30.0
  @search_vertical_from 360.0
  @search_random_from 720.0

  @enforce_keys [:action_sampler, :agent_id, :alpha]
  defstruct action_sampler: nil,
            agent_id: nil,
            rng: nil,
            alpha: nil,
            desired_object_distance: 0.025,
            use_goal_driven_actions: false,
            undo_action: nil,
            is_jumping: false,
            is_undoing_jump: false,
            pre_jump_state: nil,
            undo_jump_actions: [],
            attempting_to_find_object: false,
            tangential_angle: 0.0,
            touch_search_amount: 0.0,
            last_surface_policy_action: nil,
            telemetry: nil

  @type t :: %__MODULE__{
          action_sampler: ActionSampler.t(),
          agent_id: atom() | String.t(),
          rng: :rand.state() | nil,
          alpha: float(),
          desired_object_distance: float(),
          use_goal_driven_actions: boolean(),
          undo_action: Monty.Frameworks.Actions.Action.t() | nil,
          is_jumping: boolean(),
          is_undoing_jump: boolean(),
          pre_jump_state: Monty.Frameworks.Models.MotorSystemState.AgentState.t() | nil,
          undo_jump_actions: [Monty.Frameworks.Actions.Action.t()],
          attempting_to_find_object: boolean(),
          tangential_angle: float(),
          touch_search_amount: float(),
          last_surface_policy_action: Monty.Frameworks.Actions.Action.t() | nil,
          telemetry: SurfacePolicyTelemetry.t() | nil
        }

  @doc """
  A surface policy for `:agent_id`, with `:alpha` weighting new directions.

  `:desired_object_distance` is how far the sensor should sit from the surface,
  Monty's 2.5 cm unless told otherwise.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      action_sampler: Keyword.fetch!(options, :action_sampler),
      agent_id: Keyword.fetch!(options, :agent_id),
      alpha: Keyword.fetch!(options, :alpha),
      desired_object_distance: Keyword.get(options, :desired_object_distance, 0.025),
      use_goal_driven_actions: Keyword.get(options, :use_goal_driven_actions, false)
    }
  end

  @doc """
  One step: a jump if one is in flight or asked for, otherwise the cycle.

  The search state is reset on every step that goes on to the cycle, so falling
  off the object later starts a search from the beginning.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Cmp.Message.t() | nil,
          Cmp.Goal.t() | nil
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, ctx, observations, state, percept, goal) do
    policy = %{policy | telemetry: %SurfacePolicyTelemetry{}}

    case InformedPolicy.goal_driven_actions(policy, observations, state, goal) do
      {:result, result, policy} ->
        {result, policy}

      {:continue, policy} ->
        if searching?(policy, percept) do
          touch_object(policy, ctx, observations, state)
        else
          surface_cycle(policy, ctx, state, percept)
        end
    end
  end

  @doc """
  A jump has landed and the object is in view: carry on as if we had just moved.

  Monty overrides its `_handle_successful_jump` here so that the corrective part
  of the cycle runs next, and records that the step where the jump landed is
  telemetry rather than a curvature choice.
  """
  @impl true
  @spec handle_successful_jump(t()) :: t()
  def handle_successful_jump(%__MODULE__{} = policy) do
    %{
      policy
      | last_surface_policy_action: %MoveTangentially{
          agent_id: policy.agent_id,
          distance: 0.0,
          direction: [0.0, 0.0, 0.0]
        },
        telemetry: %SurfacePolicyTelemetry{
          pc_heading: :jump,
          avoidance_heading: false,
          z_defined_pc: nil
        }
    }
  end

  # -- the cycle ------------------------------------------------------------

  defp searching?(%__MODULE__{} = policy, percept) do
    policy.attempting_to_find_object or coverage(percept) < @coverage_to_search
  end

  defp surface_cycle(policy, ctx, state, percept) do
    policy = %{policy | touch_search_amount: 0.0}

    {policy, last_action} =
      case policy.last_surface_policy_action do
        nil ->
          # The object is already in view on the first step, so the cycle starts
          # as if a forward move had just been taken.
          {action, policy} = sample(policy, ctx, :sample_move_forward)
          {policy, action}

        action ->
          {policy, action}
      end

    {next_action, policy} = next_action(policy, ctx, state, percept, last_action)

    {%MotorPolicyResult{
       actions: if(next_action, do: [next_action], else: []),
       motor_only_step: motor_only_step?(next_action),
       telemetry: policy.telemetry
     }, %{policy | last_surface_policy_action: next_action}}
  end

  # Only the vertical orienting puts the sensor where a learning module has
  # something worth matching; everything else keeps it on the object.
  defp motor_only_step?(%OrientVertical{}), do: false
  defp motor_only_step?(nil), do: false
  defp motor_only_step?(_action), do: true

  defp next_action(policy, _ctx, state, percept, %MoveForward{}) do
    {orient_horizontal(policy, state, percept), policy}
  end

  defp next_action(policy, _ctx, state, percept, %OrientHorizontal{}) do
    {orient_vertical(policy, state, percept), policy}
  end

  defp next_action(policy, ctx, state, percept, %OrientVertical{}) do
    move_tangentially(policy, ctx, state, percept)
  end

  defp next_action(policy, _ctx, state, percept, %MoveTangentially{}) do
    if Cmp.Message.on_object?(percept) do
      {move_forward(policy, percept), policy}
    else
      # Not centred in the view: turn back toward the object before closing in.
      {orient_horizontal(policy, state, percept), policy}
    end
  end

  defp next_action(policy, _ctx, _state, _percept, _last_action), do: {nil, policy}

  # -- the four actions -----------------------------------------------------

  defp orient_horizontal(policy, state, percept) do
    rotation_degrees = orienting_angle_from_normal(policy, :horizontal, state, percept)
    {left_distance, forward_distance} = distances(rotation_degrees, percept)

    %OrientHorizontal{
      agent_id: policy.agent_id,
      rotation_degrees: rotation_degrees,
      left_distance: left_distance,
      forward_distance: forward_distance
    }
  end

  defp orient_vertical(policy, state, percept) do
    rotation_degrees = orienting_angle_from_normal(policy, :vertical, state, percept)
    {down_distance, forward_distance} = distances(rotation_degrees, percept)

    %OrientVertical{
      agent_id: policy.agent_id,
      rotation_degrees: rotation_degrees,
      down_distance: down_distance,
      forward_distance: forward_distance
    }
  end

  defp move_tangentially(policy, ctx, state, percept) do
    {action, policy} = sample(policy, ctx, :sample_move_tangentially)
    {direction, policy} = tangential_direction(policy, ctx, state)

    {%{shorten(action, coverage(percept)) | direction: direction}, policy}
  end

  defp move_forward(policy, percept) do
    %MoveForward{
      agent_id: policy.agent_id,
      distance: feature(percept, "min_depth") - policy.desired_object_distance
    }
  end

  # Near an edge the step shrinks, because a sensor that can only see a sliver of
  # the object is a sensor about to fall off it.
  defp shorten(action, coverage) when coverage < @coverage_to_shorten do
    %{action | distance: action.distance / (@search_circle_factor / coverage)}
  end

  defp shorten(action, coverage) when coverage < @coverage_to_quarter do
    %{action | distance: action.distance / 4}
  end

  defp shorten(action, _coverage), do: action

  # -- finding the object again ---------------------------------------------

  defp touch_object(policy, ctx, observations, state) do
    depth = MotorPolicies.depth_at_center(observations, policy.agent_id, @view_finder)

    if depth < @visible_depth do
      move_to_touch(policy, depth, state)
    else
      search(policy, ctx)
    end
  end

  defp move_to_touch(policy, depth, state) do
    sensor_depth =
      state
      |> Map.fetch!(policy.agent_id)
      |> Map.fetch!(:sensors)
      |> Map.fetch!(@view_finder)
      |> Map.fetch!(:position)
      |> Enum.at(2)

    action = %MoveForward{
      agent_id: policy.agent_id,
      distance: depth - policy.desired_object_distance - sensor_depth
    }

    {%MotorPolicyResult{
       actions: [action],
       motor_only_step: true,
       telemetry: policy.telemetry
     }, %{policy | attempting_to_find_object: false}}
  end

  defp search(policy, ctx) do
    policy = %{policy | attempting_to_find_object: true}
    {orientation, rotation_degrees, policy} = search_step(policy, ctx)

    radius = policy.desired_object_distance * @search_circle_factor
    radians = radians(rotation_degrees)

    # Stepping round a circle of radius r: tan gives the sideways move, and the
    # exsecant (1 - cos)/cos the forward move that brings the agent back out to
    # the same radius.
    sideways = :math.tan(radians) * radius
    forward = radius * (1.0 - :math.cos(radians)) / :math.cos(radians)

    action =
      case orientation do
        :vertical ->
          %OrientVertical{
            agent_id: policy.agent_id,
            rotation_degrees: rotation_degrees,
            down_distance: sideways,
            forward_distance: forward
          }

        :horizontal ->
          %OrientHorizontal{
            agent_id: policy.agent_id,
            rotation_degrees: rotation_degrees,
            left_distance: sideways,
            forward_distance: forward
          }
      end

    {%MotorPolicyResult{
       actions: [action],
       motor_only_step: true,
       telemetry: policy.telemetry
     },
     %{
       policy
       | touch_search_amount: policy.touch_search_amount + rotation_degrees
     }}
  end

  defp search_step(policy, ctx) do
    cond do
      policy.touch_search_amount >= @search_random_from ->
        {draw, rng} = ActionSamplers.uniform(stream(policy, ctx), 0.0, 1.0)
        {degrees, rng} = ActionSamplers.uniform(rng, -180.0, 180.0)
        orientation = if draw < 0.5, do: :vertical, else: :horizontal
        {orientation, degrees, %{policy | rng: rng}}

      policy.touch_search_amount >= @search_vertical_from ->
        {:vertical, @search_step_degrees, policy}

      true ->
        {:horizontal, @search_step_degrees, policy}
    end
  end

  # -- the geometry ---------------------------------------------------------

  # The angle that turns the sensor to face the surface, from the surface
  # normal seen in the agent's own frame: a sideways lean for a horizontal
  # orienting, an up-and-down lean for a vertical one. A normal lying in the
  # sensor's plane has no lean to read, so it is a right angle.
  defp orienting_angle_from_normal(policy, orienting, state, percept) do
    normal = surface_normal(percept)
    [x, y, z] = Rotation.apply(agent_rotation_inverse(policy, state), normal)

    lean = if orienting == :horizontal, do: x, else: y

    if z == 0.0 do
      -sign(lean) * 90.0
    else
      -(:math.atan(lean / z) * 180.0 / :math.pi())
    end
  end

  # A surface normal with the agent's own pose, seen from the agent, is the
  # identity: that is what applying the inverse of the agent's rotation does.
  defp agent_rotation_inverse(policy, state) do
    state
    |> Map.fetch!(policy.agent_id)
    |> Map.fetch!(:rotation)
    |> Rotation.invert()
  end

  # Monty has a `horizontal_distances` and a `vertical_distances`, which are the
  # same arithmetic under two names: tan for the sideways move, the exsecant for
  # forward.
  defp distances(rotation_degrees, percept) do
    radians = radians(rotation_degrees)
    depth = feature(percept, "mean_depth")

    {depth * :math.tan(radians), depth * (1.0 - :math.cos(radians)) / :math.cos(radians)}
  end

  # A direction that is mostly the last one and partly new, in the agent's own
  # frame, with theta = 0 pointing up rather than right — hence the quarter-turn
  # offsets that Monty applies to x and y.
  defp tangential_direction(policy, ctx, state) do
    {draw, rng} = ActionSamplers.uniform(stream(policy, ctx), 0.0, 1.0)
    new_target_direction = (draw - 0.5) * 2.0 * :math.pi()

    angle =
      policy.tangential_angle * (1.0 - policy.alpha) +
        new_target_direction * policy.alpha

    agent_rotation = state |> Map.fetch!(policy.agent_id) |> Map.fetch!(:rotation)

    direction =
      Rotation.apply(agent_rotation, [
        :math.cos(angle - :math.pi() / 2.0),
        :math.sin(angle + :math.pi() / 2.0),
        0.0
      ])

    {direction, %{policy | rng: rng, tangential_angle: angle}}
  end

  # -- reading the percept --------------------------------------------------

  defp coverage(percept), do: feature(percept, "object_coverage")

  defp surface_normal(percept) do
    case Cmp.Message.surface_normal(percept) do
      {:ok, normal} ->
        normal

      {:error, :no_surface_pose_vectors} ->
        raise ArgumentError, "a percept with no surface normal"
    end
  end

  defp feature(percept, name) do
    case Cmp.Message.feature(percept, name) do
      {:ok, value} -> value
      {:error, {:feature_not_found, ^name}} -> raise ArgumentError, "a percept with no #{name}"
    end
  end

  defp sample(%__MODULE__{} = policy, ctx, function) do
    rng = stream(policy, ctx)

    {action, rng} =
      apply(policy.action_sampler.__struct__, function, [
        policy.action_sampler,
        policy.agent_id,
        rng
      ])

    {action, %{policy | rng: rng}}
  end

  defp stream(%__MODULE__{} = policy, ctx),
    do: ActionSampler.stream(policy.action_sampler, policy.rng, ctx)

  defp radians(degrees), do: degrees * :math.pi() / 180.0

  defp sign(number) when number > 0, do: 1.0
  defp sign(number) when number < 0, do: -1.0
  defp sign(_zero), do: 0.0

  # -- what it remembers ----------------------------------------------------

  @doc "Starts the next episode: no jump in flight, and the search forgotten."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy) do
    %{
      InformedPolicy.reset(policy)
      | attempting_to_find_object: false,
        tangential_angle: 0.0,
        touch_search_amount: 0.0,
        last_surface_policy_action: nil,
        telemetry: nil
    }
  end

  @doc "Nothing to report: what it knows is the action it would undo."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{}), do: %{}
end
