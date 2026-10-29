defmodule Monty.Frameworks.Models.MotorPolicies do
  @moduledoc """
  Policies: how a body decides what to do with the space it is in.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py`, the largest file in
  Monty's motor system. Ported so far:

    * `...MotorPolicies.NoGoalProvided` — **ported**: raised when a policy needs
      a goal and was given none;
    * `...MotorPolicies.SurfacePolicyTelemetry` — **ported**: why a surface
      policy chose what it chose;
    * `...MotorPolicies.PolicyStatus` — **ported**: `:ready` or `:in_progress`;
    * `...MotorPolicies.MotorPolicyResult` — **ported**: what one call decided;
    * `...MotorPolicies.RuntimeMotorPolicy` and `...MotorPolicies.MotorPolicy` —
      **ported**: the two interfaces, the second a policy that can also be
      reset;
    * `...MotorPolicies.BasePolicy` — **ported**: one sampled action, whatever
      the step looked like;
    * `...MotorPolicies.InformedPolicy` — **ported**: sample while the sensor is
      on the object, step back while it is not, and jump to a goal when one
      arrives;
    * `...MotorPolicies.SurfacePolicy` — **ported**: walk the surface of an
      object, and search for it when it is lost;
    * `...MotorPolicies.NaiveScanPolicy` — **ported**: scan the object in a
      square spiral, one leg longer each time;
    * `...MotorPolicies.InformedPolicyRandomWalk` — **ported**: `InformedPolicy`'s
      walk without the rest of it, which is the default the distant configs give
      their selector;
    * `...MotorPolicies.PredefinedPolicy` — **ported**: replay the actions written
      in a JSON file, cycled for ever;
    * `...MotorPolicies.JumpToGoal` — **ported**: teleport to a goal, and undo
      the teleport when it lands somewhere useless;
    * `undo_last_action/1` — **ported**: the module-level function — Monty calls
      it `fixme_undo_last_action` — that turns an action into its opposite.

  Still planned: nothing — every class in Monty's `motor_policies.py` is ported.
  `DistantPolicySelector`, the distant agent's selector, is ported under
  `Monty.Frameworks.Models.MotorPolicySelectors`.

  A policy here is a struct plus the module named after it, so a policy can be
  stored in a selector as a value and stepped without a process — the same shape
  as `Monty.Frameworks.Models.ObjectModel` and the goal generators.
  """

  alias Monty.Frameworks.Actions.{
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    TurnLeft,
    TurnRight
  }

  @pi :math.pi()

  @doc """
  The action that would undo `action`.

  Mirrors `fixme_undo_last_action`. Only the six actions an informed policy
  samples can be undone, and each is undone by itself with its amount negated —
  a `LookDown` is undone by a `LookDown` of the opposite rotation, not by a
  `LookUp`, because the policy is reversing a move it made rather than
  commanding the agent. `MoveTangentially` keeps its direction and negates its
  distance, which is what Monty's comment on that line says.

  Monty's `fixme_` prefix is the project saying it would rather have
  `Action.undo`; the name here leaves the complaint out and the doc keeps it.
  Monty raises `TypeError` for anything else and so does this, as an
  `ArgumentError`: a policy configured with an action it cannot undo has nothing
  sensible to do with a percept that left the object. That is `docs/monty-bugs.md`
  §2.8, along with the rest of the vocabulary differences.
  """
  @spec undo_last_action(Monty.Frameworks.Actions.Action.t()) ::
          Monty.Frameworks.Actions.Action.t()
  def undo_last_action(%LookDown{} = action),
    do: %LookDown{action | rotation_degrees: -action.rotation_degrees}

  def undo_last_action(%LookUp{} = action),
    do: %LookUp{action | rotation_degrees: -action.rotation_degrees}

  def undo_last_action(%TurnLeft{} = action),
    do: %TurnLeft{action | rotation_degrees: -action.rotation_degrees}

  def undo_last_action(%TurnRight{} = action),
    do: %TurnRight{action | rotation_degrees: -action.rotation_degrees}

  def undo_last_action(%MoveForward{} = action),
    do: %MoveForward{action | distance: -action.distance}

  def undo_last_action(%MoveTangentially{} = action),
    do: %MoveTangentially{action | distance: -action.distance}

  def undo_last_action(action) do
    raise ArgumentError,
          "cannot undo #{inspect(action.__struct__)}: an informed policy samples only " <>
            "look up, look down, turn left, turn right, move forward and move tangentially"
  end

  @doc """
  The depth at the centre pixel of a sensor's view.

  Monty's `PositioningProcedure.depth_at_center`, a static method of the
  positioning protocol; the function lives with the procedures now and this is a
  delegation, so a policy can ask the question without reaching into the
  environment layer (`docs/monty-bugs.md` §2.7).
  """
  @spec depth_at_center(map(), atom() | String.t(), String.t()) :: float()
  defdelegate depth_at_center(observations, agent_id, sensor_id),
    to: Monty.Frameworks.Environments.PositioningProcedures

  @doc """
  Ask a policy what it does now that a jump has landed.

  Monty calls `self._handle_successful_jump()`, which a subclass overrides;
  here the struct's module is asked instead (`docs/monty-bugs.md` §2.9).
  """
  @spec successful_jump(struct()) :: struct()
  def successful_jump(%module{} = policy) do
    if function_exported?(module, :handle_successful_jump, 1) do
      module.handle_successful_jump(policy)
    else
      policy
    end
  end

  @doc """
  The signed change from one orientation to another, in radians.

  Monty's `theta_change`: a plain subtraction with the loop-around corrected, so
  that 0 to `3π/2` is a quarter turn back rather than three quarters forward.
  """
  @spec theta_change(float(), float()) :: float()
  def theta_change(a, b), do: enforce_pi_bounds(a - b)

  @doc """
  The same angle, brought back between `-π` and `π`.

  Monty's `enforce_pi_bounds`, as a loop of `±2π`: a plain `rem/2` would do it in
  one step, but the loop is what the angles' meaning in Monty is, and it is what
  the port follows.
  """
  @spec enforce_pi_bounds(float()) :: float()
  def enforce_pi_bounds(theta) when theta > @pi, do: enforce_pi_bounds(theta - 2.0 * @pi)

  def enforce_pi_bounds(theta) when theta < -@pi, do: enforce_pi_bounds(theta + 2.0 * @pi)

  def enforce_pi_bounds(theta), do: theta

  @doc """
  The orientation a direction in the agent's plane points in, in radians.

  Monty's `projected_angle_from_vec`: `atan2(x, y)`, in that order, because theta
  of zero means "along +y" — up in the agent's frame — rather than "along +x".
  """
  @spec projected_angle_from_vec(Monty.Geometry.Rotation.vector()) :: float()
  def projected_angle_from_vec([x, y, _z]), do: :math.atan2(x, y)

  @doc """
  The direction in the agent's plane that an orientation points in.

  Monty's `projected_vec_from_angle`. The quarter-turn offsets on `cos` and `sin`
  are what put theta of zero on +y and keep a tangential step in the plane.
  """
  @spec projected_vec_from_angle(float()) :: Monty.Geometry.Rotation.vector()
  def projected_vec_from_angle(angle) do
    [:math.cos(angle - :math.pi() / 2.0), :math.sin(angle + :math.pi() / 2.0), 0.0]
  end

  # Every parameter the ported policies take, by the name it has in a config.
  # Spelled out rather than looked up: a key turned into an atom at runtime only
  # works if some loaded module happens to have made that atom already.
  @policy_keys %{
    "agent_id" => :agent_id,
    "sensor_id" => :sensor_id,
    "alpha" => :alpha,
    "pc_alpha" => :pc_alpha,
    "desired_object_distance" => :desired_object_distance,
    "use_goal_driven_actions" => :use_goal_driven_actions,
    "max_pc_bias_steps" => :max_pc_bias_steps,
    "min_general_steps" => :min_general_steps,
    "min_heading_steps" => :min_heading_steps,
    "file" => :file,
    "fixed_amount" => :fixed_amount
  }

  @doc """
  The policy a config describes.

      policy:
        _target_: tbp.monty.frameworks.models.motor_policies.SurfacePolicyCurvatureInformed
        agent_id: agent_id_0
        alpha: 0.1
        action_sampler:
          _target_: ...ConstantSampler

  The class decides which parameters are required: each policy's own `new/1`
  fetches what it cannot do without, so a config that leaves one out fails here
  rather than at the first step of the episode.
  """
  @spec from_config(map()) :: Monty.Frameworks.Models.MotorPolicies.MotorPolicy.t()
  def from_config(%{"_target_" => _target} = config) do
    options =
      config
      |> Map.delete("_target_")
      |> Enum.map(&policy_option/1)

    Monty.Config.Target.class!(config).new(options)
  end

  defp policy_option({"action_sampler", sampler}) do
    {:action_sampler, Monty.Frameworks.Actions.ActionSamplers.from_config(sampler)}
  end

  defp policy_option({key, value}) do
    case Map.fetch(@policy_keys, key) do
      {:ok, option} -> {option, value}
      :error -> raise ArgumentError, "a motor policy takes no #{inspect(key)}"
    end
  end
end
