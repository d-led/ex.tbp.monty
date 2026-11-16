defmodule Monty.Experiment.RecognitionStrategy.RecognitionContext do
  @moduledoc """
  The episode's counters and the mode they are counting in.

  Mirrors `tbp/monty/experiment/recognition_strategy.py::RecognitionContext`.
  `step` counts every timestep; `matching_steps` and `exploring_steps` count only
  the steps where a learning module actually updated, which is why they can lag
  behind `step` — a strategy that limits *matching* steps must not be fooled by a
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

  @doc "The context of a fresh episode in `mode`."
  @spec new(ExperimentMode.t()) :: t()
  def new(mode), do: %__MODULE__{mode: mode}

  @doc """
  Counts a step, and the mode-dependent counter with it.

  Monty increments `step` on every step and `matching_steps`/`exploring_steps`
  only when a learning module updated; `:updated` is that second fact, so the
  loop says what happened rather than the context guessing.
  """
  @spec count_step(t(), boolean(), boolean()) :: t()
  def count_step(%__MODULE__{} = context, updated?, is_exploring?) do
    context = %__MODULE__{context | step: context.step + 1}
    count_update(context, updated?, is_exploring?)
  end

  defp count_update(%__MODULE__{} = context, false, _is_exploring?), do: context

  defp count_update(%__MODULE__{} = context, true, true),
    do: %__MODULE__{context | exploring_steps: context.exploring_steps + 1}

  defp count_update(%__MODULE__{} = context, true, false),
    do: %__MODULE__{context | matching_steps: context.matching_steps + 1}
end
