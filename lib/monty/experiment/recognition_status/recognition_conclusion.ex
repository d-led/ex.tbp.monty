defmodule Monty.Experiment.RecognitionStatus.RecognitionConclusion do
  @moduledoc """
  The three things a learning module can conclude.

  Mirrors `tbp/monty/experiment/recognition_status.py::RecognitionConclusion`.
  Monty's is an `Enum`, and its members are also what a recording writes, so this
  is the one place the words `"match"`, `"no_match"` and `"time_out"` become the
  atoms the rest of the port compares against — and the one place they are read
  back.

  `pose_time_out` is not one of these. Monty's loggers derive it from an
  episode's performance, and the evidence module tolerates it as a time-out if
  one is ever handed to it — but nothing sets a module's conclusion to it, so it
  is not part of the vocabulary a conclusion is written in.
  """

  @values [:match, :no_match, :time_out]

  @by_word Map.new(@values, &{Atom.to_string(&1), &1})
  @by_conclusion Map.new(@values, &{&1, Atom.to_string(&1)})

  @typedoc "What a learning module concluded."
  @type t :: :match | :no_match | :time_out

  @doc "Every conclusion, in Monty's order."
  @spec values() :: [t()]
  def values, do: @values

  @doc """
  The conclusion a recording's word means.

  `:error` for anything that is not one of the three, so a label a recording
  grows later is a refusal to read rather than a conclusion nobody defined.
  """
  @spec from_monty(term()) :: {:ok, t()} | :error
  def from_monty(word), do: Map.fetch(@by_word, word)

  @doc "The word Monty writes for a conclusion."
  @spec to_monty(t()) :: String.t()
  def to_monty(conclusion), do: Map.fetch!(@by_conclusion, conclusion)
end
