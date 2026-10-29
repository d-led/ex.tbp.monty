defmodule Monty.Experiment.RecognitionPolicyParityTest do
  @moduledoc """
  The recognition policies, held to Monty's own decisions.

  `scripts/record_monty_recognition_policy.py` asked Monty's real policies 403
  questions — every branch and boundary of thirteen configured policies — and
  wrote down the three booleans each answered. This replays them, so "when is an
  episode over" is Monty's answer and not a reading of it.

  ## What the fixture's states are

  A state is what a policy is allowed to read: `is_done`, `is_exploring`,
  `matching_steps`, and how many learning modules have concluded; plus the
  episode's counters. The states are chosen so that each policy's boundaries are
  crossed at the step or count where it turns on, in both modes.

  ## The two halves

  The decisions are the arithmetic. The refusals are the configuration: Monty
  raises `ValueError` with a particular sentence for each mistake, and a policy
  that accepted the configuration instead would run an experiment Monty refuses
  to run.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.RecognitionPolicy
  alias Monty.Experiment.RecognitionPolicy.AnyPolicy
  alias Monty.Experiment.RecognitionPolicy.MaximumSteps
  alias Monty.Experiment.RecognitionPolicy.MaxTotalSteps
  alias Monty.Experiment.RecognitionPolicy.MinEvalMaxTotalSteps
  alias Monty.Experiment.RecognitionPolicy.MinimumLMs
  alias Monty.Experiment.RecognitionPolicy.NaiveScan
  alias Monty.Experiment.RecognitionPolicy.ObjectRecognition
  alias Monty.Experiment.RecognitionPolicy.RecognitionCounter
  alias Monty.Experiment.RecognitionPolicy.RecognitionResult
  alias Monty.Experiment.RecognitionPolicy.StepLimit

  @fixture Path.expand("../../fixtures/monty_recognition_policy.json", __DIR__)

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "every recorded decision is the decision this port makes", %{fixture: fixture} do
    policies = build(fixture)

    for %{"policy" => name, "model" => model, "counter" => counter, "result" => expected} <-
          fixture["decisions"] do
      policy = Map.fetch!(policies, name)

      assert RecognitionPolicy.call(policy, model_view(model), counter_view(counter)) ==
               %RecognitionResult{
                 is_done: expected["is_done"],
                 time_out_lms: expected["time_out_lms"],
                 start_exploring: expected["start_exploring"]
               },
             "policy #{name}, model #{inspect(model)}, counter #{inspect(counter)}"
    end
  end

  test "the fixture covers every policy it names", %{fixture: fixture} do
    decided = fixture["decisions"] |> Enum.map(& &1["policy"]) |> Enum.uniq() |> Enum.sort()

    assert decided == Enum.sort(fixture["policies"])
  end

  test "a configuration Monty refuses is refused, in Monty's words", %{fixture: fixture} do
    for {name, %{"message" => message}} <- fixture["refusals"] do
      assert build_one(name) == {:error, message}, name
    end
  end

  test "a NaiveScan's step limit is the length of its spiral" do
    assert Monty.Experiment.RecognitionPolicy.NaiveScan.step_limit(90) == 1
    assert Monty.Experiment.RecognitionPolicy.NaiveScan.step_limit(10) == 73
    assert Monty.Experiment.RecognitionPolicy.NaiveScan.step_limit(5) == 307
    assert Monty.Experiment.RecognitionPolicy.NaiveScan.step_limit(1) == 8011
  end

  # -- the policies the recording names --------------------------------------

  # The recorded names are Monty's configurations written as sentences; each one
  # is built here the same way, so a mismatch in a constructor shows up as a
  # failure to compare rather than as a passing test of nothing.
  defp build(fixture) do
    fixture["policies"]
    |> Map.new(fn name -> {name, policy(name) |> elem_of_ok()} end)
  end

  defp policy("MontyIsDone"), do: Monty.Experiment.RecognitionPolicy.MontyIsDone.new()

  defp policy("MaxTotalSteps(20)"),
    do: Monty.Experiment.RecognitionPolicy.MaxTotalSteps.new(max_total_steps: 20)

  defp policy("MaximumSteps(1000, 500)"),
    do:
      Monty.Experiment.RecognitionPolicy.MaximumSteps.new(
        max_train_steps: 1000,
        max_eval_steps: 500
      )

  defp policy("StepLimit(20, 100, 1000, 500)"),
    do:
      Monty.Experiment.RecognitionPolicy.StepLimit.new(
        min_train_steps: 20,
        num_exploring_steps: 100,
        max_train_steps: 1000,
        max_eval_steps: 500
      )

  defp policy("MinimumLMs(1)"), do: Monty.Experiment.RecognitionPolicy.MinimumLMs.new(min_lms: 1)
  defp policy("MinimumLMs(3)"), do: Monty.Experiment.RecognitionPolicy.MinimumLMs.new(min_lms: 3)

  defp policy("NaiveScan(1)"),
    do: Monty.Experiment.RecognitionPolicy.NaiveScan.new(fixed_amount: 1)

  defp policy("NaiveScan(5)"),
    do: Monty.Experiment.RecognitionPolicy.NaiveScan.new(fixed_amount: 5)

  defp policy("NaiveScan(90)"),
    do: Monty.Experiment.RecognitionPolicy.NaiveScan.new(fixed_amount: 90)

  defp policy("ObjectRecognition(1000, 500, 6000)"), do: object_recognition()

  defp policy("AnyPolicy([MaximumSteps, MaxTotalSteps])"),
    do:
      Monty.Experiment.RecognitionPolicy.AnyPolicy.new(
        policies: [
          elem_of_ok(policy("MaximumSteps(1000, 500)")),
          elem_of_ok(policy("MaxTotalSteps(6000)"))
        ]
      )

  # The wrapper around a policy that fires early: the recording includes the same
  # state in both modes, which is what pins "holding back" to evaluation only.
  defp policy("MinEvalMaxTotalSteps(MaxTotalSteps(20), 20, 6000)"),
    do:
      Monty.Experiment.RecognitionPolicy.MinEvalMaxTotalSteps.new(
        wrapped: elem_of_ok(policy("MaxTotalSteps(20)")),
        min_eval_steps: 20,
        max_total_steps: 6000
      )

  defp policy("MinEvalMaxTotalSteps(ObjectRecognition, 20, 6000)"),
    do:
      Monty.Experiment.RecognitionPolicy.MinEvalMaxTotalSteps.new(
        wrapped: elem_of_ok(object_recognition()),
        min_eval_steps: 20,
        max_total_steps: 6000
      )

  defp policy("AnyPolicy([MinEvalMaxTotalSteps, StepLimit])"),
    do:
      Monty.Experiment.RecognitionPolicy.AnyPolicy.new(
        policies: [
          elem_of_ok(policy("MinEvalMaxTotalSteps(ObjectRecognition, 20, 6000)")),
          elem_of_ok(Monty.Experiment.RecognitionPolicy.StepLimit.new([]))
        ]
      )

  defp policy("MaxTotalSteps(6000)"),
    do: Monty.Experiment.RecognitionPolicy.MaxTotalSteps.new(max_total_steps: 6000)

  defp object_recognition do
    Monty.Experiment.RecognitionPolicy.ObjectRecognition.new(
      max_train_steps: 1000,
      max_eval_steps: 500,
      max_total_steps: 6000
    )
  end

  defp elem_of_ok({:ok, policy}), do: policy

  # The refusal the recorder captured is named after the constructor it used, so
  # the same constructor, given the same impossible arguments, is what has to
  # refuse here.
  defp refusals do
    done = elem_of_ok(Monty.Experiment.RecognitionPolicy.MontyIsDone.new())

    %{
      "MaxTotalSteps" => {MaxTotalSteps, [max_total_steps: 0]},
      "MaximumSteps" => {MaximumSteps, [max_train_steps: 0, max_eval_steps: 500]},
      "MaximumSteps.eval" => {MaximumSteps, [max_train_steps: 1000, max_eval_steps: 0]},
      "MinimumLMs" => {MinimumLMs, [min_lms: 0]},
      "NaiveScan" => {NaiveScan, [fixed_amount: 0]},
      "AnyPolicy" => {AnyPolicy, [policies: []]},
      "ObjectRecognition.total" =>
        {ObjectRecognition, [max_train_steps: 1000, max_eval_steps: 500, max_total_steps: 0]},
      "StepLimit.min" =>
        {StepLimit, [min_train_steps: -1, max_train_steps: 1000, max_eval_steps: 500]},
      "StepLimit.exploring" =>
        {StepLimit, [num_exploring_steps: -1, max_train_steps: 1000, max_eval_steps: 500]},
      "MinEvalMaxTotalSteps.min" => {MinEvalMaxTotalSteps, [wrapped: done, min_eval_steps: -1]},
      "MinEvalMaxTotalSteps.total" => {MinEvalMaxTotalSteps, [wrapped: done, max_total_steps: 0]},
      "MinEvalMaxTotalSteps.order" =>
        {MinEvalMaxTotalSteps, [wrapped: done, min_eval_steps: 500, max_total_steps: 20]}
    }
  end

  defp build_one(name) do
    {module, options} = Map.fetch!(refusals(), name)
    module.new(options)
  end

  # -- the recording's shapes -------------------------------------------------

  # A recording of a model has three modules; `matched_lms` says how many of them
  # concluded.
  defp model_view(%{"is_done" => is_done, "is_exploring" => is_exploring} = model) do
    matched = model["matched_lms"]

    %{
      is_done: is_done,
      is_exploring: is_exploring,
      matching_steps: model["matching_steps"],
      conclusions: Enum.map(0..2, fn index -> if index < matched, do: :match, else: nil end)
    }
  end

  defp counter_view(%{"mode" => mode} = counter) do
    %RecognitionCounter{
      step: counter["step"],
      matching_steps: counter["matching_steps"],
      exploring_steps: counter["exploring_steps"],
      mode: if(mode == "TRAIN", do: :train, else: :eval)
    }
  end
end
