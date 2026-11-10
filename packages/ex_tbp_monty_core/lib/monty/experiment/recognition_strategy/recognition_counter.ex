defmodule Monty.Experiment.RecognitionPolicy.RecognitionCounter do
  @moduledoc """
  The episode's counters, and the mode they are counting in.

  Mirrors `tbp/monty/experiment/recognition_policy.py::RecognitionCounter`.
  `step` counts every timestep; `matching_steps` and `exploring_steps` count only
  the steps where a learning module actually updated, which is why they can lag
  behind `step` — a policy that limits *matching* steps must not be fooled by a
  step where nothing was perceived.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode

  defstruct step: 0,
            matching_steps: 0,
            exploring_steps: 0,
            mode: :eval

  @type t :: %__MODULE__{
          step: non_neg_integer(),
          matching_steps: non_neg_integer(),
          exploring_steps: non_neg_integer(),
          mode: ExperimentMode.t()
        }

  @doc "Counters for a fresh episode in `mode`."
  @spec new(ExperimentMode.t()) :: t()
  def new(mode), do: %__MODULE__{mode: mode}

  @doc """
  Counts a step, and the mode-dependent counter with it.

  Monty increments `step` on every step and `matching_steps`/`exploring_steps`
  only when a learning module updated; `:updated` is that second fact, so the
  loop says what happened rather than the counter guessing.
  """
  @spec count_step(t(), boolean(), boolean()) :: t()
  def count_step(%__MODULE__{} = counter, updated?, is_exploring?) do
    counter = %__MODULE__{counter | step: counter.step + 1}
    count_update(counter, updated?, is_exploring?)
  end

  defp count_update(%__MODULE__{} = counter, false, _is_exploring?), do: counter

  defp count_update(%__MODULE__{} = counter, true, true),
    do: %__MODULE__{counter | exploring_steps: counter.exploring_steps + 1}

  defp count_update(%__MODULE__{} = counter, true, false),
    do: %__MODULE__{counter | matching_steps: counter.matching_steps + 1}
end
