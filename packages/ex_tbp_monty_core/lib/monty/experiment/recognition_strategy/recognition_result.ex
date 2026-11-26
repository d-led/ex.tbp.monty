defmodule Monty.Experiment.RecognitionStrategy.RecognitionResult do
  @moduledoc """
  What a policy decided: stop, time out the laggards, or start exploring.

  Mirrors `tbp/monty/experiment/recognition_strategy.py::RecognitionResult`. Three
  booleans, and the episode loop does three different things with them:

    * `is_done` — stop the episode.
    * `time_out_lms` — tell the learning modules that have not concluded to
      conclude (`:time_out`) before the episode ends, so the episode still has an
      answer to report.
    * `start_exploring` — switch the model into exploring mode, which is how a
      training episode keeps moving over an object it has already recognised.
    * `global_time_out` — ask for a global time-out on top of the per-module
      ones. Monty carries it and nothing reads it yet; it defaults to `true`,
      and `Any` combines it with `and` so that one strategy asking for the
      non-default wins.
  """

  defstruct is_done: false, time_out_lms: false, start_exploring: false, global_time_out: true

  @type t :: %__MODULE__{
          is_done: boolean(),
          time_out_lms: boolean(),
          start_exploring: boolean(),
          global_time_out: boolean()
        }
end
