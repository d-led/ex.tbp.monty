defmodule Monty.Test.RecordingAttention do
  @moduledoc """
  An attention system that reports what it was handed and answers what it was
  told to.

  Monty's `monty_base_test.py` holds a `MagicMock` attention system and reads the
  arguments it was called with; this is the same idea as a struct, so a case can
  read the goals and the regions in the order `_pass_goals` builds them — and the
  answer it gives is what the motor system must then receive.

  It counts its own steps, which is the only way to see from outside that the
  coordinator puts the system back: a system stepped and thrown away counts one
  step however long the episode runs.
  """

  @behaviour Monty.Attention.AttentionSystem

  defstruct notify: nil, keep: :first, steps: 0

  def new(opts \\ []),
    do: struct!(__MODULE__, Keyword.merge([notify: self(), keep: :first], opts))

  @impl true
  def step(%__MODULE__{} = system, goals, regions) do
    send(system.notify, {:attention, goals, regions})
    {%{system | steps: system.steps + 1}, keep(system.keep, goals)}
  end

  @impl true
  def reset(%__MODULE__{} = system) do
    send(system.notify, :attention_reset)
    %{system | steps: 0}
  end

  @impl true
  def state_dict(%__MODULE__{} = system), do: %{steps: system.steps}

  defp keep(_what, []), do: []
  defp keep(:first, [goal | _rest]), do: [goal]
  defp keep(:all, goals), do: goals
end
