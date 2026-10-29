defmodule Monty.Experiment.RecognitionStatus do
  @moduledoc """
  What one learning module concluded, and what it wants to say about it.

  Mirrors `tbp/monty/experiment/recognition_status.py::RecognitionStatus`. Each
  learning module decides *its own* answer — `:match`, `:no_match`, `:time_out`,
  or nothing yet — and the recognition policy is what turns several modules'
  answers into one decision about the episode. Keeping the two apart is Monty's
  design and it is what lets `MinimumLMs` ask "how many modules have concluded"
  without knowing anything about objects.

  `telemetry` is carried, not interpreted: Monty attaches whatever a module wants
  to report and nothing in the policy reads it.
  """

  @enforce_keys [:conclusion]
  defstruct conclusion: nil, telemetry: %{}

  @type conclusion :: :match | :no_match | :time_out

  @type t :: %__MODULE__{
          conclusion: conclusion() | nil,
          telemetry: map()
        }

  @doc "A module that has not concluded yet."
  @spec pending(map()) :: t()
  def pending(telemetry \\ %{}), do: %__MODULE__{conclusion: nil, telemetry: telemetry}

  @doc "A module that has concluded."
  @spec new(conclusion(), map()) :: t()
  def new(conclusion, telemetry \\ %{}),
    do: %__MODULE__{conclusion: conclusion, telemetry: telemetry}

  @doc "Whether this module has reached a conclusion."
  @spec concluded?(t()) :: boolean()
  def concluded?(%__MODULE__{conclusion: nil}), do: false
  def concluded?(%__MODULE__{}), do: true
end
