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

  Still planned: `SurfacePolicyCurvatureInformed`, a surface policy that follows
  principal curvature directions. `DistantPolicySelector`, the distant agent's
  selector, is ported under
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

  Monty's `PositioningProcedure.depth_at_center`, a static method of a module
  this port has not taken on. It lives here, where both policies can reach it,
  until the environments are ported (`docs/monty-bugs.md` §2.7).
  """
  @spec depth_at_center(map(), atom() | String.t(), String.t()) :: float()
  def depth_at_center(observations, agent_id, sensor_id) do
    depth =
      observations
      |> Map.fetch!(agent_id)
      |> Map.fetch!(sensor_id)
      |> Map.fetch!("depth")

    rows = length(depth)
    columns = depth |> hd() |> length()

    depth
    |> Enum.at(div(rows, 2))
    |> Enum.at(div(columns, 2))
  end

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
end
