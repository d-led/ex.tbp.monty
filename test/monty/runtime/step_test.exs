defmodule Monty.Runtime.StepTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp
  alias Monty.Context
  alias Monty.Runtime.{Model, Registry, Step}
  alias Monty.Test.{Messages, RecordingLearningModule, RecordingMotor, RecordingSensorModule}

  @agent "agent_id_0"

  defp sensor_module(id, opts \\ []) do
    %{
      id: id,
      agent_id: @agent,
      module: RecordingSensorModule,
      state: RecordingSensorModule.new([{:id, id} | opts])
    }
  end

  defp learning_module(id, opts \\ []) do
    %{
      id: id,
      module: RecordingLearningModule,
      state: RecordingLearningModule.new([{:id, id} | opts])
    }
  end

  defp start_model(overrides \\ []) do
    model_id = "model-#{System.unique_integer([:positive])}"

    spec =
      Map.merge(
        %{
          model_id: model_id,
          sensor_modules: [sensor_module(:patch)],
          learning_modules: [learning_module(:lm_0)],
          sm_to_lm: %{lm_0: [:patch]},
          motor: {RecordingMotor, RecordingMotor.new()}
        },
        Map.new(overrides)
      )

    start_supervised!(Supervisor.child_spec({Model, spec}, id: model_id))
    model_id
  end

  defp step(model_id, observations \\ observations(), proprioceptive_state \\ %{@agent => %{}}) do
    Model.step(model_id, observations, proprioceptive_state, Context.new(1))
  end

  defp observations do
    %{@agent => %{patch: %{"location" => [0.0, 0.0, 0.0]}}}
  end

  describe "the order of a step" do
    test "sensor modules are asked before learning modules, and the motor system last" do
      model_id = start_model()

      assert {:ok, [_action], _info} = step(model_id)

      # Mailbox order is the assertion: the percept exists before the learning
      # module is asked, and the motor system is asked after both.
      assert_receive {:sensor_state, :patch, _agent_state}
      assert_receive {:sensor_step, :patch, false, _observation}
      assert_receive {:learning_step, :lm_0, [percept], :matching}
      assert %Cmp.Message{sender_type: :sm} = percept
      assert_receive {:motor, _percept, _goals}
    end

    test "the step counter advances once per step" do
      model_id = start_model()

      {:ok, _, first} = step(model_id)
      {:ok, _, second} = step(model_id)

      assert first.step == 0
      assert second.step == 1
      assert Step.state(Registry.via({:step, model_id})).step == 2
    end
  end

  describe "routing percepts" do
    test "a percept that did not pass the filter is withheld" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, pass?: false)])

      assert {:ok, _, info} = step(model_id)
      assert info.inputs == %{lm_0: 0}
      assert_receive {:learning_step, :lm_0, [], :matching}
    end

    test "a module gets only the percepts its wiring names" do
      model_id =
        start_model(
          learning_modules: [learning_module(:lm_0), learning_module(:lm_1)],
          sm_to_lm: %{lm_0: [:patch], lm_1: []}
        )

      assert {:ok, _, info} = step(model_id)
      assert info.inputs == %{lm_0: 1, lm_1: 0}
    end

    test "a hierarchy input arrives only if the receiver also saw a sensor percept" do
      model_id =
        start_model(
          learning_modules: [
            learning_module(:lm_0, output: Messages.output()),
            learning_module(:lm_1)
          ],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]},
          lm_to_lm: %{lm_1: [:lm_0]}
        )

      assert {:ok, _, info} = step(model_id)
      # lm_1 sees its own sensor percept and, because of that, lm_0's output.
      assert info.inputs == %{lm_0: 1, lm_1: 2}

      assert_receive {:learning_step, :lm_1,
                      [%Cmp.Message{sender_type: :sm}, %Cmp.Message{sender_type: :lm}], :matching}
    end

    test "with no passing sensor percept, the hierarchy stays silent too" do
      model_id =
        start_model(
          sensor_modules: [sensor_module(:patch, pass?: false)],
          learning_modules: [learning_module(:lm_0), learning_module(:lm_1)],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]},
          lm_to_lm: %{lm_1: [:lm_0]}
        )

      assert {:ok, _, info} = step(model_id)
      assert info.inputs == %{lm_0: 0, lm_1: 0}
    end
  end

  describe "voting" do
    test "every module votes before any module hears the result" do
      model_id =
        start_model(
          learning_modules: [learning_module(:lm_0), learning_module(:lm_1)],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]},
          lm_to_lm_vote: %{lm_0: [:lm_1], lm_1: [:lm_0]}
        )

      assert {:ok, _, info} = step(model_id)

      votes = [assert_receive({:send_vote, _}), assert_receive({:send_vote, _})]
      assert Enum.sort(Enum.map(votes, &elem(&1, 1))) == [:lm_0, :lm_1]

      assert_receive {:receive_votes, :lm_0, [:lm_1]}
      assert_receive {:receive_votes, :lm_1, [:lm_0]}
      assert %{sent: 2, used: 2, deadline_hit?: false} = info.votes
    end

    test "no vote matrix means no vote round at all" do
      model_id = start_model()

      assert {:ok, _, info} = step(model_id)
      assert info.votes == %{sent: 0, used: 0, deadline_hit?: false, timed_out: []}
      refute_received {:send_vote, _}
    end
  end

  describe "goals and the motor system" do
    test "the motor system receives the first sensor percept and the proposed goals" do
      {:ok, goal} =
        Cmp.Goal.new(%{location: [0.0, 0.0, 0.0], sender_id: "lm_0", sender_type: :gsg})

      model_id = start_model(learning_modules: [learning_module(:lm_0, goals: [goal])])

      assert {:ok, [_action], info} = step(model_id)
      assert info.goals == 1
      assert_receive {:motor, %Cmp.Message{location: location}, [received_goal]}
      assert location == [0.0, 0.0, 0.0]
      assert received_goal.sender_type == :gsg
    end

    test "a motor-only step withholds percepts from learning modules on the next step" do
      model_id = start_model(motor: {RecordingMotor, RecordingMotor.new(motor_only?: true)})

      assert {:ok, _, _} = step(model_id)
      assert {:ok, _, info} = step(model_id)

      assert_receive {:sensor_step, :patch, true, _observation}
      assert info.inputs == %{lm_0: 0}
    end
  end

  describe "supervision" do
    test "a learning module that dies is replaced, and the next step still runs" do
      model_id = start_model()
      assert {:ok, _, _} = step(model_id)

      key = {:learning_module, model_id, :lm_0}
      [{original, _}] = Registry.lookup(key)
      ref = Process.monitor(original)
      Process.exit(original, :kill)
      assert_receive {:DOWN, ^ref, :process, ^original, :killed}

      # Wait for the supervisor itself to have handled the child's exit, rather
      # than polling a clock: a system message is answered only after the exit
      # message that came before it, so the replacement exists by then.
      _ = :sys.get_state(Monty.Runtime.Model.via(model_id))

      replacement = Registry.lookup(key)
      assert [{pid, _}] = replacement
      assert pid != original
      assert {:ok, _, info} = step(model_id)
      assert info.inputs == %{lm_0: 1}
      assert_receive {:learning_step, :lm_0, [_percept], :matching}
    end
  end

  describe "determinism" do
    test "two models with the same wiring and seed report the same step" do
      first_model = start_model()
      second_model = start_model()

      {:ok, first_actions, first_info} = step(first_model)
      {:ok, second_actions, second_info} = step(second_model)

      assert first_actions == second_actions
      assert Map.delete(first_info, :duration_us) == Map.delete(second_info, :duration_us)
    end
  end
end
