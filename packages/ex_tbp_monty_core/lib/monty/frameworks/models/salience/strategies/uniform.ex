defmodule Monty.Frameworks.Models.Salience.Strategies.Uniform do
  @moduledoc """
  Every pixel is equally interesting.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/uniform.py::Uniform`,
  and it is Monty's default: a salience module with no strategy configured looks
  everywhere, which is what makes the module's inhibition of return the only
  thing steering it. A real attention model — `vocus2` — is a strategy of its
  own and is still to come.
  """

  @behaviour Monty.Frameworks.Models.Salience.Strategies.Protocol.SalienceStrategy

  defstruct []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def call(%__MODULE__{}, _ctx, _rgba, depth) do
    Enum.map(depth, fn row -> Enum.map(row, fn _pixel_depth -> 1.0 end) end)
  end
end
