defmodule Monty.Frameworks.Models.MotorPolicies.SurfacePolicyCurvatureInformed do
  @moduledoc """
  A surface policy that follows the principal curvature directions when it can.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::SurfacePolicyCurvatureInformed`.
  `SurfacePolicy` walks the surface in a direction that is mostly the last one;
  this policy does that only when the surface tells it nothing, and otherwise
  heads along the object's own lines — the rim of a cup, the handle of a mug — by
  following a principal curvature direction.

  ## Which line it follows, and for how long

  It starts on the **smallest** principal curvature (in absolute value) and
  follows it for `max_pc_bias_steps`, then the largest, then back, alternating
  while the directions stay defined. When they stop being defined it falls back
  to the standard momentum step, and it will not consider curvature again until
  it has taken `min_general_steps` of those.

  ## Two reasons to ignore a curvature direction

  A direction that points mostly along the agent's **z** axis is ignored: on the
  rim of a cup the curvature direction comes out pointing away from the surface,
  which is an artefact of the agent re-orienting against a noisy estimate. And a
  direction that would take the sensor where it **has already been** is turned
  away from it by a search over headings — the first attempt flips a curvature
  direction that has just started, later ones rotate the heading at random, the
  search looks less strictly as it fails, and if nothing is free after a hundred
  attempts the original heading is kept.

  ## What it shares with `SurfacePolicy`

  In Monty this is a subclass and overrides `__call__` (to record where a
  tangential step came from), `tangential_direction` and `reset`. Here it is a
  second struct carrying the same fields, calling `SurfacePolicy.surface_step/6`
  and overriding the one method, which that step asks of the policy's own module
  (`docs/monty-bugs.md` §2.9).
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Cmp
  alias Monty.Frameworks.Actions.ActionSamplers
  alias Monty.Frameworks.Actions.ActionSamplers.ActionSampler
  alias Monty.Frameworks.Models.MotorPolicies
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicyResult, SurfacePolicy}
  alias Monty.Frameworks.Models.MotorPolicies.SurfacePolicyTelemetry
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @pi :math.pi()

  # A heading within a third of pi of a place we have been is a conflict; the
  # divisor grows every twenty failed attempts, so the search relaxes as it goes.
  @conflict_divisor 3
  @attempts_per_relaxation 20

  # How many passes over the history the search may make before giving up.
  @max_search_steps 100

  # Only the most recent sensations are worth avoiding; older ones are behind us.
  @locations_to_check 50

  # Two places closer than this are the same place.
  @same_place 0.025

  # Two surface normals further apart than this are different surfaces, and
  # passing near them is not a conflict at all.
  @same_surface :math.pi() / 4.0

  @enforce_keys [
    :action_sampler,
    :agent_id,
    :alpha,
    :pc_alpha,
    :max_pc_bias_steps,
    :min_general_steps,
    :min_heading_steps
  ]
  defstruct action_sampler: nil,
            agent_id: nil,
            rng: nil,
            alpha: nil,
            pc_alpha: nil,
            max_pc_bias_steps: nil,
            min_general_steps: nil,
            min_heading_steps: nil,
            desired_object_distance: 0.025,
            use_goal_driven_actions: false,
            undo_action: nil,
            is_jumping: false,
            is_undoing_jump: false,
            pre_jump_state: nil,
            undo_jump_actions: [],
            attempting_to_find_object: false,
            tangential_angle: nil,
            tangential_vec: nil,
            touch_search_amount: 0.0,
            last_surface_policy_action: nil,
            telemetry: nil,
            min_dir_pref: true,
            using_pc_guide: false,
            ignoring_pc_counter: 0,
            following_heading_counter: 0,
            following_pc_counter: 0,
            continuous_pc_steps: 0,
            prev_angle: nil,
            tangent_locs: [],
            tangent_norms: [],
            pc_is_z_defined: false,
            setting_new_heading: false

  @type t :: %__MODULE__{
          action_sampler: ActionSampler.t(),
          agent_id: atom() | String.t(),
          rng: :rand.state() | nil,
          alpha: float(),
          pc_alpha: float(),
          max_pc_bias_steps: pos_integer(),
          min_general_steps: non_neg_integer(),
          min_heading_steps: non_neg_integer(),
          desired_object_distance: float(),
          use_goal_driven_actions: boolean(),
          undo_action: Monty.Frameworks.Actions.Action.t() | nil,
          is_jumping: boolean(),
          is_undoing_jump: boolean(),
          pre_jump_state: Monty.Frameworks.Models.MotorSystemState.AgentState.t() | nil,
          undo_jump_actions: [Monty.Frameworks.Actions.Action.t()],
          attempting_to_find_object: boolean(),
          tangential_angle: float() | nil,
          tangential_vec: Rotation.vector() | nil,
          touch_search_amount: float(),
          last_surface_policy_action: Monty.Frameworks.Actions.Action.t() | nil,
          telemetry: SurfacePolicyTelemetry.t() | nil,
          min_dir_pref: boolean(),
          using_pc_guide: boolean(),
          ignoring_pc_counter: non_neg_integer(),
          following_heading_counter: non_neg_integer(),
          following_pc_counter: non_neg_integer(),
          continuous_pc_steps: non_neg_integer(),
          prev_angle: float() | nil,
          tangent_locs: [Rotation.vector()],
          tangent_norms: [Rotation.vector() | nil],
          pc_is_z_defined: boolean(),
          setting_new_heading: boolean()
        }

  @doc """
  A curvature-following surface policy.

  `:alpha` weights a standard step towards the previous one, `:pc_alpha` the
  same for the moving average of a curvature direction. `:max_pc_bias_steps`,
  `:min_general_steps` and `:min_heading_steps` are Monty's three counters, and
  they are required because their right values are a property of the experiment.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    policy = %__MODULE__{
      action_sampler: Keyword.fetch!(options, :action_sampler),
      agent_id: Keyword.fetch!(options, :agent_id),
      alpha: Keyword.fetch!(options, :alpha),
      pc_alpha: Keyword.fetch!(options, :pc_alpha),
      max_pc_bias_steps: Keyword.fetch!(options, :max_pc_bias_steps),
      min_general_steps: Keyword.fetch!(options, :min_general_steps),
      min_heading_steps: Keyword.fetch!(options, :min_heading_steps),
      desired_object_distance: Keyword.get(options, :desired_object_distance, 0.025),
      use_goal_driven_actions: Keyword.get(options, :use_goal_driven_actions, false)
    }

    # Monty starts this counter at the minimum: the first well-defined curvature
    # should be usable straight away.
    %{policy | ignoring_pc_counter: policy.min_general_steps}
  end

  @doc """
  One step, with the place a tangential move came from remembered first.

  Monty records the sensor's location and surface normal whenever the previous
  action was the vertical orienting, because the tangential step follows it
  immediately: those are the places the sensor has walked to, as opposed to the
  corrective movements that put it there.
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
    policy
    |> record_location(percept)
    |> SurfacePolicy.surface_step(ctx, observations, state, percept, goal)
  end

  defp record_location(%__MODULE__{} = policy, %Cmp.Message{} = percept) do
    if match?(%Monty.Frameworks.Actions.OrientVertical{}, policy.last_surface_policy_action) do
      %{
        policy
        | tangent_locs: policy.tangent_locs ++ [percept.location],
          tangent_norms: policy.tangent_norms ++ [surface_normal(percept)]
      }
    else
      policy
    end
  end

  defp record_location(policy, _percept), do: policy

  # -- the overridden tangential direction ----------------------------------

  @doc """
  The direction of a tangential move: along a curvature line, or by momentum.

  Monty's override of `SurfacePolicy.tangential_direction`. Curvature is only
  considered when the pose is fully defined *and* enough standard steps have been
  taken since the last time curvature was followed.
  """
  @spec tangential_direction(t(), Monty.Context.t(), map(), Cmp.Message.t() | nil) ::
          {Rotation.vector(), t()}
  def tangential_direction(%__MODULE__{} = policy, ctx, state, percept) do
    policy = %{policy | pc_is_z_defined: false, setting_new_heading: false}

    {direction, policy} =
      if follow_curvature?(policy, percept) do
        pc_guided_step(policy, ctx, state, percept)
      else
        policy = if policy.using_pc_guide, do: reset_pc_buffers(policy), else: policy

        standard_tang_step(
          %{policy | using_pc_guide: false, ignoring_pc_counter: policy.ignoring_pc_counter + 1},
          ctx,
          state
        )
      end

    {direction, update_action_details(policy, percept)}
  end

  # Why this heading, for the log: which curvature it followed, whether it had to
  # turn away from somewhere it had been, and the curvature it ignored as z.
  defp update_action_details(policy, percept) do
    pc_heading =
      cond do
        not policy.using_pc_guide -> :no
        policy.min_dir_pref -> :min
        true -> :max
      end

    z_defined_pc =
      if policy.pc_is_z_defined,
        do: {surface_normal(percept), curvature_directions(percept)},
        else: nil

    %{
      policy
      | telemetry: %SurfacePolicyTelemetry{
          pc_heading: pc_heading,
          avoidance_heading: policy.setting_new_heading,
          z_defined_pc: z_defined_pc
        }
    }
  end

  defp follow_curvature?(policy, percept) do
    pose_defined?(percept) and policy.ignoring_pc_counter >= policy.min_general_steps
  end

  # -- following a curvature line -------------------------------------------

  defp pc_guided_step(policy, ctx, state, percept) do
    policy = %{policy | using_pc_guide: true} |> check_for_preference_change()

    rotated =
      Rotation.apply(agent_rotation_inverse(policy, state), curvature_direction(policy, percept))

    if z_defined?(rotated) do
      # The curvature points out of the surface in the agent's own frame, which
      # says more about the re-orienting than about the object.
      standard_tang_step(%{policy | pc_is_z_defined: true}, ctx, state)
    else
      continue_along_curvature(policy, ctx, state, rotated)
    end
  end

  defp continue_along_curvature(policy, ctx, state, rotated) do
    policy =
      policy
      |> update_tangential_reps({:vec, rotated})
      |> check_for_flipped_pc()

    policy = avoid_revisiting_locations(policy, ctx, state)
    direction = world_direction(policy, state)

    if policy.setting_new_heading do
      # A bad heading while following curvature: break out of it, and make sure
      # enough plain steps happen before curvature is followed again.
      {direction, %{reset_pc_buffers(policy) | following_heading_counter: 0}}
    else
      # A heading that is good enough to carry on with, smoothed so that the path
      # does not jump where the estimate of the curvature shifts slightly.
      policy =
        if policy.prev_angle == nil,
          do: %{policy | prev_angle: policy.tangential_angle},
          else: pc_moving_average(policy)

      {direction,
       %{
         policy
         | following_pc_counter: policy.following_pc_counter + 1,
           continuous_pc_steps: policy.continuous_pc_steps + 1
       }}
    end
  end

  # The curvature to follow is the smaller one, or the larger one once the
  # preference has flipped. `argmin`/`argmax` take the first of equal values,
  # which is why the comparisons here are `<=` and `>=`.
  defp curvature_direction(policy, percept) do
    {first, second} = curvature_directions(percept)
    {a, b} = curvatures(percept)

    smaller_first? = abs(a) <= abs(b)
    follow_first? = if policy.min_dir_pref, do: smaller_first?, else: not smaller_first?

    if follow_first?, do: first, else: second
  end

  defp curvature_directions(percept) do
    case Cmp.Message.curvature_directions(percept) do
      {:ok, directions} ->
        directions

      {:error, :no_surface_pose_vectors} ->
        raise ArgumentError, "a percept with no curvature directions"
    end
  end

  defp curvatures(percept) do
    case feature(percept, "principal_curvatures") do
      [a, b | _rest] -> {a, b}
      other -> raise ArgumentError, "a percept with no principal curvatures: #{inspect(other)}"
    end
  end

  # -- the standard, momentum step ------------------------------------------

  defp standard_tang_step(policy, ctx, state) do
    {draw, rng} = ActionSamplers.uniform(stream(policy, ctx), 0.0, 1.0)
    policy = %{policy | rng: rng}

    policy =
      if policy.tangential_angle == nil do
        update_tangential_reps(policy, {:angle, (draw - 0.5) * 2.0 * @pi})
      else
        target = (draw - 0.5) * 2.0 * @pi
        difference = MotorPolicies.theta_change(policy.tangential_angle, target)
        blended = policy.tangential_angle + policy.alpha * difference

        update_tangential_reps(policy, {:angle, MotorPolicies.enforce_pi_bounds(blended)})
      end

    policy =
      if policy.following_heading_counter >= policy.min_heading_steps do
        policy = avoid_revisiting_locations(policy, ctx, state)

        # A new heading restarts the count, so the next few steps follow it.
        if policy.setting_new_heading, do: %{policy | following_heading_counter: 0}, else: policy
      else
        policy
      end

    {world_direction(policy, state),
     %{policy | following_heading_counter: policy.following_heading_counter + 1}}
  end

  # -- the representations of a heading -------------------------------------

  defp update_tangential_reps(policy, {:vec, vector}) do
    angle = MotorPolicies.projected_angle_from_vec(vector)

    %{
      policy
      | tangential_angle: angle,
        tangential_vec: MotorPolicies.projected_vec_from_angle(angle)
    }
  end

  defp update_tangential_reps(policy, {:angle, angle}) do
    vector = MotorPolicies.projected_vec_from_angle(angle)

    %{
      policy
      | tangential_vec: vector,
        tangential_angle: MotorPolicies.projected_angle_from_vec(vector)
    }
  end

  # A tangential move in the world, which is the agent's own heading turned by
  # however the agent is facing.
  defp world_direction(policy, state) do
    agent_rotation = state |> Map.fetch!(policy.agent_id) |> Map.fetch!(:rotation)
    Rotation.apply(agent_rotation, policy.tangential_vec)
  end

  # -- the counters that decide what happens next ---------------------------

  defp check_for_preference_change(policy) do
    if policy.following_pc_counter == policy.max_pc_bias_steps do
      %{
        policy
        | min_dir_pref: not policy.min_dir_pref,
          following_pc_counter: 0,
          continuous_pc_steps: 0,
          prev_angle: nil
      }
    else
      policy
    end
  end

  # Leaving a stretch of curvature following, or choosing a new heading: the
  # counters start again, but the heading does not, so momentum carries on.
  defp reset_pc_buffers(policy) do
    %{
      policy
      | ignoring_pc_counter: 0,
        using_pc_guide: false,
        continuous_pc_steps: 0,
        prev_angle: nil
    }
  end

  # A curvature direction that flipped while the surface did not has probably
  # flipped arbitrarily, so flip it back.
  defp check_for_flipped_pc(policy) do
    flipped? =
      policy.prev_angle != nil and
        abs(MotorPolicies.theta_change(policy.prev_angle, policy.tangential_angle + @pi)) <=
          @same_surface

    if flipped?,
      do: update_tangential_reps(policy, {:vec, negate(policy.tangential_vec)}),
      else: policy
  end

  defp pc_moving_average(policy) do
    difference = MotorPolicies.theta_change(policy.prev_angle, policy.tangential_angle)
    blended = policy.tangential_angle + policy.pc_alpha * difference

    policy
    |> update_tangential_reps({:angle, MotorPolicies.enforce_pi_bounds(blended)})
    |> Map.put(:prev_angle, policy.tangential_angle)
  end

  # -- not walking where it has been ----------------------------------------

  # Turns the heading away from a place the sensor has already been, and answers
  # the policy with `setting_new_heading` set if it had to.
  defp avoid_revisiting_locations(%__MODULE__{tangent_locs: []} = policy, _ctx, _state),
    do: policy

  defp avoid_revisiting_locations(policy, ctx, state) do
    current = List.last(policy.tangent_locs)
    inverse = agent_rotation_inverse(policy, state)

    rotated_locations =
      policy.tangent_locs
      |> Enum.map(&SpatialArithmetics.subtract(&1, current))
      |> then(&Rotation.apply(inverse, &1))

    search = %{
      locations: rotated_locations,
      original: policy.tangential_vec,
      conflict_divisor: @conflict_divisor,
      attempts: 0,
      first_attempt: true
    }

    policy
    |> Map.put(:setting_new_heading, false)
    |> search_for_heading(ctx, search)
    |> then(&update_tangential_reps(&1, {:vec, &1.tangential_vec}))
  end

  defp search_for_heading(policy, ctx, search) do
    {policy, search} = resolve_conflicts(policy, ctx, search)

    cond do
      not search.conflicted? ->
        policy

      search.attempts >= @max_search_steps ->
        # Nothing was free: the original heading is better than none.
        update_tangential_reps(policy, {:vec, search.original})

      true ->
        search = %{search | attempts: search.attempts + 1, conflicted?: false}

        search_for_heading(policy, ctx, %{search | conflict_divisor: relaxed_divisor(search)})
    end
  end

  defp resolve_conflicts(policy, ctx, search) do
    search = Map.put(search, :conflicted?, false)

    indices = candidate_indices(search.locations)

    Enum.reduce(indices, {policy, search}, fn index, {policy, search} ->
      if conflict?(policy, search, index) do
        resolve_conflict(policy, ctx, %{search | conflicted?: true})
      else
        {policy, search}
      end
    end)
  end

  defp candidate_indices(locations) do
    last = length(locations) - 1
    Enum.to_list(max(0, last - @locations_to_check)..(last - 1)//1)
  end

  defp conflict?(policy, search, index) do
    location = Enum.at(search.locations, index)
    normal = Enum.at(policy.tangent_norms, index)

    SpatialArithmetics.get_angle_beefed_up(policy.tangential_vec, location) <=
      @pi / search.conflict_divisor and
      SpatialArithmetics.get_angle_beefed_up(List.last(policy.tangent_norms), normal) <=
        @same_surface and
      SpatialArithmetics.magnitude(location) <= @same_place
  end

  # The first attempt along a curvature direction that has only just started
  # turns it round instead of guessing: the direction is good, its sign is not.
  # That is not a new heading — if it resolves the conflict, curvature is still
  # followed.
  defp resolve_conflict(policy, ctx, %{first_attempt: true} = search) do
    if policy.using_pc_guide and policy.continuous_pc_steps == 0 do
      {update_tangential_reps(policy, {:vec, negate(search.original)}),
       %{search | first_attempt: false}}
    else
      random_heading(policy, ctx, search)
    end
  end

  defp resolve_conflict(policy, ctx, search), do: random_heading(policy, ctx, search)

  defp random_heading(policy, ctx, search) do
    limits = min(max(0.1 + search.attempts / @max_search_steps, 0.0), 1.0)
    {draw, rng} = ActionSamplers.uniform(stream(policy, ctx), -limits, limits)
    rotation = rotate_about_z(draw * @pi)

    policy =
      update_tangential_reps(policy, {:vec, Rotation.apply(rotation, search.original)})
      |> Map.put(:rng, rng)
      |> Map.put(:setting_new_heading, true)

    {policy, %{search | first_attempt: false}}
  end

  defp relaxed_divisor(search) do
    if rem(search.attempts, @attempts_per_relaxation) == 0,
      do: search.conflict_divisor + 1,
      else: search.conflict_divisor
  end

  defp rotate_about_z(angle) do
    case Rotation.from_axis_angle([0.0, 0.0, 1.0], angle) do
      {:ok, rotation} -> rotation
      {:error, :zero_axis} -> raise ArgumentError, "the z axis cannot be a zero axis"
    end
  end

  defp negate([x, y, z]), do: [-x, -y, -z]

  # -- reading the percept --------------------------------------------------

  defp pose_defined?(percept), do: feature(percept, "pose_fully_defined") == true

  # `argmax(abs(...)) == 2`, with `argmax` taking the first of equal values: the z
  # component has to be strictly the largest for the direction to count as z.
  defp z_defined?([x, y, z]), do: abs(z) > abs(x) and abs(z) > abs(y)

  defp agent_rotation_inverse(policy, state) do
    state |> Map.fetch!(policy.agent_id) |> Map.fetch!(:rotation) |> Rotation.invert()
  end

  defp surface_normal(percept) do
    case Cmp.Message.surface_normal(percept) do
      {:ok, normal} -> normal
      {:error, _no_pose_vectors} -> nil
    end
  end

  defp feature(percept, name) do
    case Cmp.Message.feature(percept, name) do
      {:ok, value} -> value
      {:error, {:feature_not_found, ^name}} -> nil
    end
  end

  defp stream(policy, ctx), do: ActionSampler.stream(policy.action_sampler, policy.rng, ctx)

  # -- what it remembers ----------------------------------------------------

  @doc "Starts the next episode: the surface's own state goes with it."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy) do
    %{
      SurfacePolicy.reset(policy)
      | tangential_angle: nil,
        tangential_vec: nil,
        min_dir_pref: true,
        using_pc_guide: false,
        ignoring_pc_counter: policy.min_general_steps,
        following_heading_counter: 0,
        following_pc_counter: 0,
        continuous_pc_steps: 0,
        prev_angle: nil,
        tangent_locs: [],
        tangent_norms: [],
        pc_is_z_defined: false,
        setting_new_heading: false
    }
  end

  @doc "Nothing beyond what a surface policy reports."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{}), do: %{}
end
