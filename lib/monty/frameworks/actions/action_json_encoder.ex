defmodule Monty.Frameworks.Actions.ActionJSONEncoder do
  @moduledoc """
  An action as the map it crosses a boundary as.

  Mirrors `tbp/monty/frameworks/actions/actions.py::ActionJSONEncoder`, which is
  a `JSONEncoder` subclass whose only job is `dict(action)`. The JSON library is
  not this module's business — `Jason.encode!/1` on the map it answers is the
  same object Monty produces — so what is ported here is the value mapping, not
  the encoder plumbing.
  """

  @doc """
  The action as a map: its name under `"action"`, then every parameter.
  """
  @spec encode(Monty.Frameworks.Actions.Action.t()) :: map()
  def encode(%module{} = action), do: module.to_map(action)
end
