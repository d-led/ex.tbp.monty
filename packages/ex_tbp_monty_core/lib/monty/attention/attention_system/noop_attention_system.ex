defmodule Monty.Attention.AttentionSystem.NoopAttentionSystem do
  @moduledoc """
  Attention that has no opinion: Monty's
  `attention/attention_system.py::NoopAttentionSystem`.

  Every goal the goal generator proposes is passed through, and nothing is
  recorded. A task uses this when it wants the attention seam to exist without
  paying for it.
  """

  @behaviour Monty.Attention.AttentionSystem

  defstruct []

  @type t :: %__MODULE__{}

  @impl Monty.Attention.AttentionSystem
  def step(%__MODULE__{} = system, goals, _regions), do: {system, goals}

  @impl Monty.Attention.AttentionSystem
  def reset(%__MODULE__{} = system), do: system

  @impl Monty.Attention.AttentionSystem
  def state_dict(%__MODULE__{}), do: %{}
end
