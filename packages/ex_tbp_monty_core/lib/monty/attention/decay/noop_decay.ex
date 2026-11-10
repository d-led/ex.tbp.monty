defmodule Monty.Attention.Decay.NoopDecay do
  @moduledoc """
  Decay that forgets nothing: Monty's `attention/decay.py::NoopDecay`.

  Every weight survives every step, which is what a task wants when the thing
  being looked for does not move and the sensor's attention should not fade.
  """

  @behaviour Monty.Attention.Decay.VoxelGridWeightDecay

  defstruct []

  @type t :: %__MODULE__{}

  @doc """
  Leave the grid as it is.

  The decay itself is the first argument, as it is for every decay, and there is
  nothing in it to read: this decay is the decision not to have one.
  """
  @impl Monty.Attention.Decay.VoxelGridWeightDecay
  def decay(%__MODULE__{}, %Monty.Attention.VoxelGrid{} = grid), do: grid
end
