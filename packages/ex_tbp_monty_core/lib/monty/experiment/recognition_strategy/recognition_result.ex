defmodule Monty.Experiment.RecognitionPolicy.RecognitionResult do
  @moduledoc """
  What a policy decided: stop, time out the laggards, or start exploring.

  Mirrors `tbp/monty/experiment/recognition_policy.py::RecognitionResult`. Three
  booleans, and the episode loop does three different things with them:

    * `is_done` — stop the episode.
    * `time_out_lms` — tell the learning modules that have not concluded to
      conclude (`:time_out`) before the episode ends, so the episode still has an
      answer to report.
    * `start_exploring` — switch the model into exploring mode, which is how a
      training episode keeps moving over an object it has already recognised.
  """

  defstruct is_done: false, time_out_lms: false, start_exploring: false

  @type t :: %__MODULE__{
          is_done: boolean(),
          time_out_lms: boolean(),
          start_exploring: boolean()
        }
end
