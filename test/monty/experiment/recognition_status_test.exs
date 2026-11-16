defmodule Monty.Experiment.RecognitionStatusTest do
  use ExUnit.Case, async: true

  alias Monty.Experiment.RecognitionStatus
  alias Monty.Experiment.RecognitionStatus.RecognitionConclusion

  # Monty's `RecognitionConclusion` is the whole vocabulary of what a module can
  # conclude: three values, and the string it writes is how a recording and a
  # match criterion say them.
  describe "the conclusions a module can reach" do
    test "are Monty's three, in its order" do
      assert RecognitionConclusion.values() == [:match, :no_match, :time_out]
    end

    test "read back from the words a recording writes" do
      for conclusion <- RecognitionConclusion.values() do
        assert RecognitionConclusion.from_monty(RecognitionConclusion.to_monty(conclusion)) ==
                 {:ok, conclusion}
      end
    end

    # `pose_time_out` is a performance label in Monty's loggers, not something a
    # learning module concludes, so it must not become one by being accepted.
    test "a word that is not one of them is refused, not guessed" do
      assert RecognitionConclusion.from_monty("pose_time_out") == :error
      assert RecognitionConclusion.from_monty("MATCH") == :error
      assert RecognitionConclusion.from_monty(nil) == :error
    end
  end

  describe "a module that has not concluded" do
    test "is pending" do
      status = RecognitionStatus.pending()

      assert status == %RecognitionStatus{conclusion: nil}
      refute RecognitionStatus.concluded?(status)
    end
  end

  describe "a module that has concluded" do
    test "says which conclusion it reached" do
      status = RecognitionStatus.new(:match)

      assert status.conclusion == :match
      assert RecognitionStatus.concluded?(status)
    end
  end
end
