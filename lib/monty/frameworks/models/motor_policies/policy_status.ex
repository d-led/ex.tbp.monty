defmodule Monty.Frameworks.Models.MotorPolicies.PolicyStatus do
  @moduledoc """
  Whether a policy is done, or still working on the goal in hand.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::PolicyStatus`. Monty's
  values are the strings `"ready"` and `"in_progress"`; here they are atoms,
  which is what the rest of this port does with small closed sets, and the
  strings appear only on a wire — as with `Monty.Cmp.Message.sender_type`. The
  enum members are values rather than functions, so the atoms are the whole of
  this module (`docs/monty-bugs.md` §2.8).
  """

  @type t :: :ready | :in_progress
end
