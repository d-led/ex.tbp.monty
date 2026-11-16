defmodule Monty.Experiment.RecognitionStatus do
  @moduledoc """
  What one learning module concluded, and what it wants to say about it.

  Mirrors `tbp/monty/experiment/recognition_status.py::RecognitionStatus`. Each
  learning module decides *its own* answer — `:match`, `:no_match`, `:time_out`,
  or nothing yet — and the recognition strategy is what turns several modules'
  answers into one decision about the episode. Keeping the two apart is Monty's
  design and it is what lets `MinimumLMs` ask "how many modules have concluded"
  without knowing anything about objects.
  """

  alias Monty.Experiment.RecognitionStatus.RecognitionConclusion

  # Monty's dataclass defaults its conclusion, so a status exists before the
  # module has decided anything.
  defstruct conclusion: nil

  @type t :: %__MODULE__{conclusion: RecognitionConclusion.t() | nil}

  @doc "A module that has not concluded yet."
  @spec pending() :: t()
  def pending, do: %__MODULE__{}

  @doc "A module that has concluded."
  @spec new(RecognitionConclusion.t()) :: t()
  def new(conclusion), do: %__MODULE__{conclusion: conclusion}

  @doc "Whether this module has reached a conclusion."
  @spec concluded?(t()) :: boolean()
  def concluded?(%__MODULE__{conclusion: nil}), do: false
  def concluded?(%__MODULE__{}), do: true
end
