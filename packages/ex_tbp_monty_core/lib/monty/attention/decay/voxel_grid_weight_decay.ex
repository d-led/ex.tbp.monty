defmodule Monty.Attention.Decay.VoxelGridWeightDecay do
  @moduledoc """
  The one method every decay has: Monty's `attention/decay.py::VoxelGridWeightDecay`.

  Monty writes it as a `Protocol` over `__call__` and the call mutates the grid in
  place. Nothing here mutates — a `%Monty.Attention.VoxelGrid{}` is a value — so
  `decay/2` takes a grid and answers the decayed one, and the decay itself is the
  first argument because Monty's collaborator is a bound method and ours is a
  value (`%Monty.Attention.Decay.NoopDecay{}`,
  `%Monty.Attention.Decay.LinearWeightDecay{rate: 0.1}`).

  It carries no `__call__` of its own in Monty either: a protocol with one method
  and no body is a type, and a type here is a behaviour.
  """

  alias Monty.Attention.VoxelGrid

  @doc """
  One step of decay: a decay and a grid in, the decayed grid out.

  The decay leads because Monty's bound `__call__` already carries it; a caller
  that has the grid first has to name the decay twice.
  """
  @callback decay(term(), VoxelGrid.t()) :: VoxelGrid.t()
end
