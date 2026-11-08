defmodule Monty.Memento.Snapshotable do
  @moduledoc """
  Objects that can save and restore their internal state: Monty's
  `memento.py::Snapshotable`.

  Monty writes this as a `runtime_checkable` `Protocol` — structural typing, so
  anything with the two methods counts — and uses it where an object has to be
  reset to a snapshot without the caller knowing its class.

  Elixir has no structural typing, so the same promise is a behaviour: a module
  that implements these two callbacks is snapshotable, and says so by `use`ing
  or `@behaviour`ing this module. The state that goes in and comes back is the
  object's own — a struct here rather than a mutated `self` — which is why the
  callbacks take it and return it rather than returning `:ok`.
  """

  @typedoc "An object that can be snapshotted. Any struct; the memento is opaque."
  @type snapshotable :: term()

  @doc """
  The object's state, as a memento.

  What goes in is the object's business. Monty's convention, followed by every
  class that implements this: what an episode learns is in the memento, and what
  an episode *saw* is not — a buffer of percepts belongs to the episode that
  produced it.
  """
  @callback state_dict(snapshotable()) :: Monty.Memento.t()

  @doc """
  The object, reset to what a memento says.

  Returns the object rather than mutating it: a step in this port is a value, and
  so is a restore.
  """
  @callback load_state_dict(snapshotable(), Monty.Memento.t()) :: snapshotable()
end
