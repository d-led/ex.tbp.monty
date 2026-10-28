defmodule Monty.Frameworks.Actions.Action do
  @moduledoc """
  Something an agent can be told to do.

  Mirrors `tbp/monty/frameworks/actions/actions.py::Action`, which is a protocol
  every action satisfies rather than a class they inherit from: an action is a
  name and a bag of parameters, and what makes it an action is that an
  environment knows how to perform it.

  Monty's `__iter__` yields the name first and then every parameter, which is
  exactly what `to_map/1` answers — that map is the JSON object an action
  crosses a boundary as, and `...Actions.ActionJSONDecoder` reads it back.

  Monty's `sample/3` and `act/2` are not here: sampling needs the action
  samplers and acting needs an actuator, and both belong to whatever environment
  performs the actions. The `*ActionSampler` and `*Actuator` protocols stay
  planned with them, for the same reason.
  """

  @doc """
  The action's name, as it appears in a configuration or on the wire.

  Snake case of the module name, as Monty's `action_name()` is the snake case of
  the class name.
  """
  @callback name() :: String.t()

  @doc """
  The action as a map: its name under `"action"`, then every parameter.

  A `dict(action)` in Monty, and the object an action is sent as.
  """
  @callback to_map(t()) :: map()

  @type t :: struct()
end
