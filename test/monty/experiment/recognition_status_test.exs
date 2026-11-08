defmodule Monty.Experiment.RecognitionStatusTest do
  use ExUnit.Case, async: true

  alias Monty.Experiment.RecognitionStatus

  describe "a module that has not concluded" do
    test "is pending, and carries what it wants to report" do
      status = RecognitionStatus.pending(%{hyps: 3})

      assert status.conclusion == nil
      assert status.telemetry == %{hyps: 3}
      refute RecognitionStatus.concluded?(status)
    end

    test "defaults to reporting nothing" do
      assert RecognitionStatus.pending().telemetry == %{}
    end
  end

  describe "a module that has concluded" do
    test "says which conclusion it reached" do
      status = RecognitionStatus.new(:match)

      assert status.conclusion == :match
      assert RecognitionStatus.concluded?(status)
    end

    test "keeps the telemetry the module attached" do
      assert RecognitionStatus.new(:time_out, %{steps: 12}).telemetry == %{steps: 12}
    end
  end
end
