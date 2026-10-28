defmodule Monty.Frameworks.Actions do
  @moduledoc """
  What an agent can be told to do.

  Mirrors `tbp/monty/frameworks/actions/actions.py`, which holds one protocol and
  fourteen actions:

    * `...Actions.Action` — **ported**: the interface an action satisfies, its
      name and the map it is sent as;
    * the fourteen actions — **ported**: `...Actions.LookDown`,
      `...Actions.LookUp`, `...Actions.MoveForward`,
      `...Actions.MoveTangentially`, `...Actions.OrientHorizontal`,
      `...Actions.OrientVertical`, `...Actions.SetAgentPitch`,
      `...Actions.SetAgentPose`, `...Actions.SetSensorPitch`,
      `...Actions.SetSensorPose`, `...Actions.SetSensorRotation`,
      `...Actions.SetYaw`, `...Actions.TurnLeft`, `...Actions.TurnRight`;
    * `...Actions.ActionJSONEncoder` and `...Actions.ActionJSONDecoder` —
      **ported**: the map an action becomes and the action a map becomes.

  An action is a value: a motor policy builds one, an environment performs it,
  and nothing in between inspects more than its name and parameters. That is why
  the degrees in these structs are degrees rather than radians — every field is
  copied from Monty's constructor unchanged, so an action built here and an
  action built there are the same object with a different spelling.

  The `*ActionSampler` and `*Actuator` protocols in the same Python file stay
  planned. Sampling is how a random policy chooses an action and actuating is
  how an environment performs one; both belong with the environment, and this
  port has no environment to give them to yet.
  """
end
