defmodule Monty.Memento do
  @moduledoc """
  A snapshot of an object's internal state, as an opaque map: Monty's
  `memento.py`.

  Monty defines `Memento` as `Mapping[str, Any]` and nothing more — the *shape*
  is deliberately not specified, because a memento is only ever handed back to
  the object that made it. What a caller may do with one is save it, log it, or
  give it back; reading a key out of it is what every logging bug looks like.

  Here the same holds, with the one addition Python does not need: an Elixir map
  can be pattern-matched by anyone, so the discipline is written down instead of
  being enforced by the type.
  """

  @typedoc """
  A state dict: whatever an object's `state_dict/1` returned.

  Keys are atoms and values are whatever the object put there — a graph memory, a
  list of percepts, a telemetry log. Treat it as opaque outside the module that
  produces it.
  """
  @type t :: %{optional(atom() | String.t()) => term()}
end
