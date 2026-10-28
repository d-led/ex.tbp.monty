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
    * `undo_last_action/1` — **ported**: the module-level function — Monty calls
      it `fixme_undo_last_action` — that turns an action into its opposite.

  Still planned, in the order they are needed: `SurfacePolicy` (follow the
  surface, which is what every surface-agent experiment uses), `JumpToGoal` and
  the look-at policy that `DistantPolicySelector` routes to, then the policies
  that are only for particular experiments (`PredefinedPolicy`,
  `NaiveScanPolicy`, `InformedPolicyRandomWalk`) and
  `SurfacePolicyCurvatureInformed`.

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
end
