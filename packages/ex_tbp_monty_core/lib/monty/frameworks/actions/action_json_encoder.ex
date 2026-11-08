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

  A tuple is not JSON, and the two pose actions carry their rotation as one
  `{w, x, y, z}` — Monty's `quaternion` crosses its boundary as those four
  numbers, so they cross this one as a list.
  """
  @spec encode(Monty.Frameworks.Actions.Action.t()) :: map()
  def encode(%module{} = action), do: action |> module.to_map() |> plain()

  defp plain({a, b, c, d}), do: [plain(a), plain(b), plain(c), plain(d)]
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, plain(value)} end)
  defp plain(value), do: value
end
