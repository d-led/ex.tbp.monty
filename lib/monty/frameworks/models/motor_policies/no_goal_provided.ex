defmodule Monty.Frameworks.Models.MotorPolicies.NoGoalProvided do
  @moduledoc """
  Raised when a policy needs a goal and was given none.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::NoGoalProvided`, a
  `RuntimeError` with nothing in it. It is raised rather than returned because
  the caller that reaches it has already decided there must be a goal: a
  selector routed a goal to a policy that reaches it, and the goal was `nil`.
  """

  defexception message: "a goal is required by this policy, and none was provided"
end
