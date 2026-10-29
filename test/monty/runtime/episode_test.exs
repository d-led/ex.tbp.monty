defmodule Monty.Runtime.EpisodeTest do
  use ExUnit.Case, async: true

  alias Monty.Experiment.RecognitionPolicy.{ObjectRecognition, StepLimit}
  alias Monty.Runtime.{Episode, Model}
  alias Monty.Test.{RecordingLearningModule, RecordingMotor, RecordingSensorModule}

  @agent "agent_id_0"

  # An environment that always shows the same thing, and reports that it was
  # asked — with the actions it was given.
  defp environment do
    notify = self()

    fn actions ->
      send(notify, {:environment_step, actions})

      observations = %{@agent => %{patch: %{"location" => [0.0, 0.0, 0.0]}}}
      {observations, %{@agent => %{}}}
    end
  end

  defp start_model(learning_module_options \\ []) do
    model_id = "episode-#{System.unique_integer([:positive])}"

    spec = %{
      model_id: model_id,
      sensor_modules: [
        %{
          id: :patch,
          agent_id: @agent,
          module: RecordingSensorModule,
          state: RecordingSensorModule.new(id: :patch)
        }
      ],
      learning_modules: [
        %{
          id: :lm_0,
          module: RecordingLearningModule,
          state: RecordingLearningModule.new([{:id, :lm_0} | learning_module_options])
        }
      ],
      sm_to_lm: %{lm_0: [:patch]},
      motor: {RecordingMotor, RecordingMotor.new([])}
    }

    start_supervised!(Supervisor.child_spec({Model, spec}, id: model_id))
    model_id
  end

  describe "an episode that reaches a conclusion" do
    test "stops as soon as the model is done" do
      model_id = start_model(terminal: :match)

      result = Episode.run(model_id, environment(), mode: :eval)

      # One step is enough: the model asks the module for its terminal
      # condition after the module has stepped.
      assert result.steps == 1
      assert result.done?
      refute result.timed_out?
      assert result.terminal_states == %{lm_0: :match}
    end

    test "asks the environment once per step, and the first time with no action" do
      model_id = start_model(terminal: :match)

      _result = Episode.run(model_id, environment(), mode: :eval)

      assert_receive {:environment_step, []}
      refute_received {:environment_step, _}
    end
  end

  describe "an episode that never concludes" do
    test "is timed out at the step limit, and the model is told" do
      model_id = start_model()

      result = Episode.run(model_id, environment(), mode: :eval, max_steps: 3)

      assert result.steps == 3
      assert result.timed_out?
      assert result.done?

      assert result.terminal_states == %{lm_0: :time_out}
      assert Model.done?(model_id)
    end
  end

  describe "training and evaluating" do
    test "a training episode hands what it saw to memory" do
      model_id = start_model()

      _result = Episode.run(model_id, environment(), mode: :train, max_steps: 2)

      assert_receive {:set_experiment_mode, :lm_0, :train}
      assert_receive {:update_ltm, :lm_0}
    end

    test "an evaluation episode writes nothing" do
      model_id = start_model()

      _result = Episode.run(model_id, environment(), mode: :eval, max_steps: 2)

      assert_receive {:set_experiment_mode, :lm_0, :eval}
      refute_received {:update_ltm, _}
    end
  end

  describe "a second episode" do
    test "starts from a cleared model rather than from where the first one stopped" do
      model_id = start_model()

      first = Episode.run(model_id, environment(), mode: :eval, max_steps: 2)
      second = Episode.run(model_id, environment(), mode: :eval, max_steps: 2)

      assert first.steps == 2
      assert length(second.infos) == 2
      assert hd(second.infos).step == 0
    end
  end

  describe "the recognition policy" do
    test "decides when the episode stops, not a step budget" do
      model_id = start_model()

      {:ok, policy} =
        ObjectRecognition.new(max_train_steps: 1000, max_eval_steps: 3, max_total_steps: 100)

      result = Episode.run(model_id, environment(), mode: :eval, policy: policy, max_steps: 500)

      # Three matching steps: the policy's limit, well below the ceiling that
      # would have been used had the budget been the thing that stopped it.
      assert result.steps == 3
      assert result.timed_out?
    end

    test "asks for exploration, and the next step is exploratory" do
      model_id = start_model()

      {:ok, policy} =
        StepLimit.new(min_train_steps: 1, max_train_steps: 1000, max_eval_steps: 500)

      result = Episode.run(model_id, environment(), mode: :train, policy: policy)

      # The module never concludes, so nothing but the policy could have asked
      # for this: one matching step is enough for it to want to explore.
      assert Enum.map(result.infos, & &1.step_type) == [:matching, :exploratory]
      assert Model.state(model_id).step_type == :exploratory
    end
  end
end
