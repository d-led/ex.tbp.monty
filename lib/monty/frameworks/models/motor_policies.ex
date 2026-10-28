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
      the step looked like.

  Still planned, in the order they are needed: `InformedPolicy` (move towards a
  goal, explore when there is none), `SurfacePolicy` (follow the surface, which
  is what every surface-agent experiment uses), `JumpToGoal` and the look-at
  policy that `DistantPolicySelector` routes to, then the two policies that are
  only for particular experiments (`PredefinedPolicy`, `NaiveScanPolicy`) and
  `SurfacePolicyCurvatureInformed`.

  A policy here is a struct plus the module named after it, so a policy can be
  stored in a selector as a value and stepped without a process — the same shape
  as `Monty.Frameworks.Models.ObjectModel` and the goal generators.
  """
end
