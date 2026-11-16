defmodule Monty.Test.RecordingStrategy do
  @moduledoc """
  A recognition strategy that answers what it was told, and says that it was asked.

  Monty's tests use `MagicMock` for this. On the BEAM the equivalent is a strategy
  that sends a message when it runs, so a test can tell "answered not done" from
  "never asked" — which is the only way to see that a combination stops at the
  first strategy that fires.
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @doc "A strategy for `tag` that answers `answer`, as `{module, state}`."
  @spec new(atom(), RecognitionResult.t()) ::
          {module(), %{tag: atom(), answer: RecognitionResult.t()}}
  def new(tag, answer), do: {__MODULE__, %{tag: tag, answer: answer}}

  @doc "Reports `{:asked, tag}` to the caller, then answers."
  @spec call(map(), term(), %{tag: atom(), answer: RecognitionResult.t()}) ::
          RecognitionResult.t()
  def call(_model, _counter, %{tag: tag, answer: answer}) do
    send(self(), {:asked, tag})
    answer
  end
end
