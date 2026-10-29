defmodule Monty.Experiment.RecognitionPolicy do
  @moduledoc """
  What counts as "the episode is over".

  Mirrors `tbp/monty/experiment/recognition_policy.py::RecognitionPolicy`. Each
  learning module decides its own answer; a policy turns those answers, plus the
  step counters, into the one decision the episode loop asks for:
  `%RecognitionResult{is_done: ..., time_out_lms: ..., start_exploring: ...}`.

  ## The model, as a policy sees it

  Monty's policies are handed the model and read four things off it. Rather than
  reach into the runtime's processes, a policy here is given those four things as
  a map — that is what keeps the decision logic pure and comparable with Monty's
  own answers (`scripts/record_monty_recognition_policy.py`). The episode loop is
  what builds the map, from the model it is holding.

  ## Policies are `{module, state}`

  Each policy is a module plus the numbers it was configured with, which is how
  the rest of this port composes behaviour (`Monty.Experiment.RecognitionPolicy.call/3`),
  and it means `AnyPolicy` can hold a list of them without knowing what any of
  them are.

  ## What is *not* here

  Monty's policies log and telemeter when they decide (`logger.info`,
  `telemeter.info`). The decision is what is compared; the logging is the
  experiment's business, so it is not on this path.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionCounter
  alias Monty.Experiment.RecognitionPolicy.RecognitionResult
  alias Monty.Experiment.RecognitionStatus

  @typedoc """
  The model, as a recognition policy may read it.

  `is_done` is Monty's `model.is_done` — every learning module that matters has
  concluded. `conclusions` is each module's answer, in module order, with `nil`
  for a module that has not concluded.
  """
  @type model :: %{
          required(:is_done) => boolean(),
          required(:is_exploring) => boolean(),
          required(:matching_steps) => non_neg_integer(),
          required(:conclusions) => [RecognitionStatus.conclusion() | nil]
        }

  @typedoc "A policy and the numbers it was configured with."
  @type t :: {module(), term()}

  @doc """
  Applies a policy to a model and the episode's counters.

  The whole reason a policy is a module and a state: this is the only place that
  need know the shape.
  """
  @spec call(t(), model(), RecognitionCounter.t()) :: RecognitionResult.t()
  def call({module, state}, model, counter), do: module.call(model, counter, state)

  @doc """
  The signature every policy module implements.

  `state` is whatever the policy's `new/1` decided to keep — Monty keeps them as
  instance attributes, which is the same thing without the object.
  """
  @callback call(model(), RecognitionCounter.t(), state :: term()) :: RecognitionResult.t()
end
