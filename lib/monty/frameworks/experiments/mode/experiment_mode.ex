defmodule Monty.Frameworks.Experiments.Mode.ExperimentMode do
  @moduledoc """
  Which half of an experiment a step belongs to.

  Mirrors `tbp/monty/frameworks/experiments/mode.py::ExperimentMode`. Monty makes
  it an enum with two members whose *values* are the strings `"train"` and
  `"eval"`; here it is a plain atom, `:train` or `:eval`, and the strings only
  appear where a config or a log needs them.

  The distinction is not decoration: the recognition policies choose their step
  limit by mode (`max_train_steps` or `max_eval_steps`), and Monty's minimum-eval
  rule applies only while evaluating.
  """

  @typedoc "`tbp.monty`'s `ExperimentMode`."
  @type t :: :train | :eval

  @doc "The two modes, in Monty's declaration order."
  @spec all() :: [t()]
  def all, do: [:eval, :train]

  @doc "The mode's value, which is what Monty prints and stores."
  @spec to_string(t()) :: String.t()
  def to_string(:eval), do: "eval"
  def to_string(:train), do: "train"

  @doc "A mode from its stored value, or `:error` for one that is not a mode."
  @spec from_string(String.t()) :: {:ok, t()} | :error
  def from_string("eval"), do: {:ok, :eval}
  def from_string("train"), do: {:ok, :train}
  def from_string(_other), do: :error
end
