defmodule Monty.Runtime.StepTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp
  alias Monty.Context
  alias Monty.Geometry.{OrientationMatrix, Rotation}
  alias Monty.Runtime.{Model, Registry, Step}

  alias Monty.Test.{
    Messages,
    RaisingMotor,
    RecordingLearningModule,
    RecordingMotor,
    RecordingSensorModule
  }

  @agent "agent_id_0"
  @identity Rotation.to_matrix(Rotation.identity())

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

    start_supervised!(Supervisor.child_spec({Model, spec}, id: model_id, restart: :temporary))
    model_id
  end

  defp step(model_id, observations \\ observations(), proprioceptive_state \\ %{@agent => %{}}) do
    Model.step(model_id, observations, proprioceptive_state, Context.new(1))
  end

  defp observations do
    %{@agent => %{patch: %{"location" => [0.0, 0.0, 0.0]}}}
  end

  # A vote shaped as `send_out_vote` answers it: one place on one object, from a
  # sensor standing at `location` in the body and looking straight forward.
  defp vote_from(location) do
    {:ok, message} =
      Cmp.Message.new(
        location: [0.0, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" => %OrientationMatrix{value: @identity},
          "pose_fully_defined" => true
        },
        non_morphological_features: %{},
        confidence: 0.7,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "learning_module",
        sender_type: :lm
      )

    %{possible_states: %{"mug" => [message]}, sensed_pose_rel_body: [location | @identity]}
  end

  # A goal a module proposes, named after the module, so a test can read the
  # order the goals arrived in off the list.
  defp goal_from(id) do
    {:ok, goal} = Cmp.Goal.new(%{sender_id: to_string(id), sender_type: :gsg})
    goal
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
    test "a percept that did not pass the filter is withheld, and the module is not stepped" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, pass?: false)])

      assert {:ok, _, info} = step(model_id)
      assert info.inputs == %{lm_0: 0}

      # Monty skips a module it has nothing for, and tells it so: no step, and
      # nothing to count as processed.
      refute_received {:learning_step, _, _, _}
      assert_receive {:lm_processing, :lm_0, false}
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

  describe "what a module is told it is looking at" do
    test "the object under its sensor, named by the world's ids" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, semantic_id: 1)])

      # The experiment knows the world's ids; the percept carries the one its
      # centre pixel saw. Together they are the stepwise target — Monty's
      # `_set_stepwise_targets` — and it is recorded before the module steps.
      :ok = Model.fixme_set_ground_truth(model_id, nil, semantic_id_to_label: %{1 => "mug"})

      assert {:ok, _, _info} = step(model_id)

      assert_receive {:stepwise_target, :lm_0, "mug"}
      assert_receive {:learning_step, :lm_0, _percepts, :matching}
    end

    test "and `no_label` when the world cannot name it" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, semantic_id: 1)])

      # No map: a world without semantics, or a sensor without a label. Monty
      # answers `no_label` here, and so does this, so an episode's log always has
      # one entry per step rather than a gap.
      :ok = Model.fixme_set_ground_truth(model_id, nil)

      assert {:ok, _, _info} = step(model_id)

      assert_receive {:stepwise_target, :lm_0, "no_label"}
    end

    test "and `no_label` for an id the world's map does not list" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, semantic_id: 9)])

      :ok = Model.fixme_set_ground_truth(model_id, nil, semantic_id_to_label: %{1 => "mug"})

      assert {:ok, _, _info} = step(model_id)

      assert_receive {:stepwise_target, :lm_0, "no_label"}
    end
  end

  describe "voting" do
    test "every module votes before any module hears the result" do
      model_id =
        start_model(
          learning_modules: [
            learning_module(:lm_0, vote: vote_from([0.0, 0.0, 0.0])),
            learning_module(:lm_1, vote: vote_from([0.1, 0.0, 0.0]))
          ],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]},
          lm_to_lm_vote: %{lm_0: [:lm_1], lm_1: [:lm_0]}
        )

      assert {:ok, _, info} = step(model_id)

      votes = [assert_receive({:send_vote, _}), assert_receive({:send_vote, _})]
      assert Enum.sort(Enum.map(votes, &elem(&1, 1))) == [:lm_0, :lm_1]

      # Each module hears the other's vote moved out of the sender's sensor and
      # into its own: the two sensors are a hand's width apart along x, so the
      # same place on the object is a different vector from each of them.
      assert_receive {:receive_votes, :lm_0,
                      %{"mug" => [%Cmp.Message{location: [heard_by_lm_0, _, _]}]}}

      assert_receive {:receive_votes, :lm_1,
                      %{"mug" => [%Cmp.Message{location: [heard_by_lm_1, _, _]}]}}

      assert_in_delta heard_by_lm_0, -0.1, 1.0e-12
      assert_in_delta heard_by_lm_1, 0.1, 1.0e-12

      assert %{sent: 2, used: 2, deadline_hit?: false} = info.votes
    end

    test "every module is asked what the round left it believing, heard or not" do
      # The module that heard nothing is the one that can have nothing possible:
      # the round concludes `:no_match` for it, or lets it back out of one.
      model_id =
        start_model(
          learning_modules: [
            learning_module(:lm_0, vote: vote_from([0.0, 0.0, 0.0])),
            learning_module(:lm_1, vote: vote_from([0.0, 0.0, 0.0]))
          ],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]},
          lm_to_lm_vote: %{lm_0: [], lm_1: [:lm_0]}
        )

      assert {:ok, _, _info} = step(model_id)

      # The module with no sources is still part of the round, and hears nothing.
      assert_receive {:receive_votes, :lm_1, %{"mug" => [_heard]}}
      assert_receive {:receive_votes, :lm_0, %{}}

      assert_receive {:update_stats_after_vote, :lm_0}
      assert_receive {:update_stats_after_vote, :lm_1}
    end

    test "no vote matrix means no vote round at all" do
      model_id = start_model()

      assert {:ok, _, info} = step(model_id)
      assert info.votes == %{sent: 0, used: 0, deadline_hit?: false, timed_out: []}
      refute_received {:send_vote, _}
    end
  end

  describe "goals and the motor system" do
    # Monty's `monty_base_test.py::test_pass_goals_collects_all_goals_from_learning_and_sensor_modules_and_filters_them_through_the_attention_system`,
    # the whole of `MontyBasePrivateTest`. Monty calls `_pass_goals` directly and
    # holds a `MagicMock` attention system; here the attention system is the
    # function the step state carries, so the case reads what it was handed and
    # what the motor system then received.
    test "the goals are the learning modules' then the sensors', the regions the sensors' then the modules'" do
      parent = self()
      goals = fn id, n -> List.duplicate(goal_from(id), n) end
      region = fn id -> %Cmp.AttentionRegion{locations: [[0.0, 0.0, 0.0]], weights: [id]} end

      attention = fn given_goals, given_regions ->
        send(parent, {:attention, given_goals, given_regions})
        [Enum.at(given_goals, 0)]
      end

      model_id =
        start_model(
          sensor_modules: [
            sensor_module(:patch, goals: goals.(:patch, 0), region: region.(0)),
            sensor_module(:view, goals: goals.(:view, 2), region: region.(1))
          ],
          learning_modules: [
            learning_module(:lm_0, goals: goals.(:lm_0, 0), region: region.(2)),
            learning_module(:lm_1, goals: goals.(:lm_1, 1), region: region.(3)),
            learning_module(:lm_2, goals: goals.(:lm_2, 2), region: region.(4))
          ],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch], lm_2: [:view]},
          attention: attention
        )

      assert {:ok, [_action], _info} = step(model_id)

      # Learning modules first, then sensors, each in the order they were wired.
      assert_receive {:attention, given_goals, given_regions}
      assert Enum.map(given_goals, & &1.sender_id) == ["lm_1", "lm_2", "lm_2", "view", "view"]

      # The other way round for the regions: the sensors propose where they are
      # looking before the modules do.
      assert Enum.map(given_regions, &hd(&1.weights)) == [0, 1, 2, 3, 4]

      # What attention answered is what the motors were given.
      assert_receive {:motor, _percept, [received_goal]}
      assert received_goal.sender_id == "lm_1"
    end

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

  describe "deciding the episode" do
    test "an evaluation ends when a module recognises the object" do
      model_id =
        start_model(
          experiment_mode: :eval,
          learning_modules: [learning_module(:lm_0, terminal: :match)]
        )

      assert {:ok, _, info} = step(model_id)

      assert info.terminal_states == %{lm_0: :match}
      assert info.done?
      assert Model.done?(model_id)
    end

    test "an evaluation waits out its minimum number of steps first" do
      model_id =
        start_model(
          experiment_mode: :eval,
          min_eval_steps: 2,
          learning_modules: [learning_module(:lm_0, terminal: :match)]
        )

      {:ok, _, first} = step(model_id)
      {:ok, _, second} = step(model_id)
      {:ok, _, third} = step(model_id)

      # Monty compares strictly: two steps is not yet "more than two".
      refute first.done?
      refute second.done?
      assert third.done?
    end

    test "a training episode starts exploring once a module recognises the object" do
      model_id =
        start_model(
          experiment_mode: :train,
          num_exploratory_steps: 3,
          learning_modules: [learning_module(:lm_0, terminal: :match)]
        )

      assert {:ok, _, info} = step(model_id)
      assert info.step_type == :exploratory
      refute info.done?

      assert {:ok, _, _} = step(model_id)
      assert_receive {:exploratory_step, :lm_0, _percepts, :exploratory}
    end

    test "a training episode explores in the step its modules gave up, before its minimum" do
      model_id =
        start_model(
          experiment_mode: :train,
          num_exploratory_steps: 1,
          min_train_steps: 5,
          learning_modules: [learning_module(:lm_0, terminal: :no_match)]
        )

      # A module's own step is where it concludes it found nothing possible, and
      # the model reads that conclusion rather than asking for one — a minimum
      # number of steps is not a reason to keep looking at an object that has
      # already been given up on.
      assert {:ok, _, info} = step(model_id)

      assert info.terminal_states == %{lm_0: :no_match}
      assert info.step_type == :exploratory
      refute_received {:update_terminal_condition, :lm_0}
    end

    test "an exploration that saw enough steps ends the episode" do
      model_id =
        start_model(
          experiment_mode: :train,
          num_exploratory_steps: 1,
          learning_modules: [learning_module(:lm_0, terminal: :match)]
        )

      # The first step concludes, so the second is an exploratory step, and
      # with one exploratory step required the episode is over.
      {:ok, _, _} = step(model_id)
      assert {:ok, _, info} = step(model_id)

      assert info.step_type == :exploratory
      assert info.done?
    end

    test "a module that never concluded is timed out when the episode ends" do
      model_id =
        start_model(
          experiment_mode: :eval,
          learning_modules: [learning_module(:lm_0, terminal: :match), learning_module(:lm_1)],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]}
        )

      assert {:ok, _, info} = step(model_id)

      assert info.terminal_states == %{lm_0: :match, lm_1: :time_out}
      assert_receive {:set_terminal_state, :lm_1, :time_out}
      refute_received {:set_terminal_state, :lm_0, _}
    end

    test "every module giving up is a conclusion without asking the criterion" do
      model_id =
        start_model(
          experiment_mode: :eval,
          min_eval_steps: 1,
          learning_modules: [
            learning_module(:lm_0, terminal: :no_match),
            learning_module(:lm_1, terminal: :no_match)
          ],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]}
        )

      # The modules' own step is what concludes they cannot match, and the model
      # reads those conclusions in the same step: nothing is left to agree on, so
      # no criterion and no re-asking are needed. Only the evaluation's minimum
      # number of steps still has to pass.
      {:ok, _, first} = step(model_id)
      assert first.terminal_states == %{lm_0: :no_match, lm_1: :no_match}
      refute_received {:update_terminal_condition, _}

      {:ok, _, second} = step(model_id)
      assert second.done?
      assert second.terminal_states == %{lm_0: :no_match, lm_1: :no_match}
      refute_received {:update_terminal_condition, _}
    end

    test "a conclusion survives the steps that follow it" do
      model_id =
        start_model(
          experiment_mode: :train,
          num_exploratory_steps: 5,
          learning_modules: [learning_module(:lm_0, terminal: :match)]
        )

      # The first step concludes and switches to exploring; the exploratory
      # step asks nothing about terminal conditions, so the conclusion stays.
      {:ok, _, first} = step(model_id)
      {:ok, _, second} = step(model_id)

      assert first.terminal_states == %{lm_0: :match}
      assert second.terminal_states == %{lm_0: :match}
      assert second.step_type == :exploratory
      refute second.done?
    end
  end

  describe "counting the steps that mattered" do
    defp matching_steps(model_id), do: Step.state(Registry.via({:step, model_id})).matching_steps

    test "a step that reached a module counts" do
      model_id = start_model()

      {:ok, _, _} = step(model_id)
      assert matching_steps(model_id) == 1
    end

    test "a step that reached no module does not count" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, pass?: false)])

      {:ok, _, _} = step(model_id)
      assert matching_steps(model_id) == 0
    end

    test "a step that only carried a location does not count either" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, features?: false)])

      {:ok, _, _} = step(model_id)
      assert matching_steps(model_id) == 0
    end

    # The experiment counts its own steps from the report, not from the model's
    # counter, so the report has to answer the same question: a percept that
    # reached a module is not the same thing as one it processed.
    test "a step a module processed is reported as one" do
      model_id = start_model()

      {:ok, _, info} = step(model_id)
      assert info.processed?
    end

    test "a location-only step is reported as one no module processed" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, features?: false)])

      {:ok, _, info} = step(model_id)

      # Delivered, so the module buffered the location — and nothing to process.
      assert info.inputs == %{lm_0: 1}
      refute info.processed?
    end

    test "a step whose percept never passed is reported as one no module processed" do
      model_id = start_model(sensor_modules: [sensor_module(:patch, pass?: false)])

      {:ok, _, info} = step(model_id)
      refute info.processed?
    end
  end

  describe "the episode boundary" do
    test "clearing the episode forgets its counters, conclusions and the done flag" do
      model_id =
        start_model(
          experiment_mode: :eval,
          learning_modules: [learning_module(:lm_0, terminal: :match)]
        )

      {:ok, _, _} = step(model_id)
      assert Model.done?(model_id)

      :ok = Model.reset_episode(model_id)
      state = Step.state(Registry.via({:step, model_id}))

      assert state.step == 0
      assert state.matching_steps == 0
      assert state.terminal_states == %{}
      assert state.step_type == :matching
      refute Model.done?(model_id)
    end

    test "the end of an episode hands the episode to long-term memory" do
      model_id = start_model()

      {:ok, _, _} = step(model_id)
      :ok = Model.update_ltm(model_id)

      assert_receive {:update_ltm, :lm_0}
    end

    test "and records what that memory came from, after it was written" do
      model_id = start_model()

      {:ok, _, _} = step(model_id)
      :ok = Model.update_ltm(model_id)

      assert_receive {:update_ltm, :lm_0}
      assert_receive {:ground_truth, :lm_0}
    end

    test "the model can be told which object the episode is about" do
      model_id = start_model()
      target = %{"object_name" => "mug", "quat_rotation" => [0.0, 0.0, 0.0, 1.0]}

      :ok = Model.fixme_set_ground_truth(model_id, target)

      assert_receive {:set_target, :lm_0, ^target}
    end

    test "the model can be told whether this episode trains or evaluates" do
      model_id = start_model()

      :ok = Model.set_experiment_mode(model_id, :train)

      assert_receive {:set_experiment_mode, :lm_0, :train}
      assert Step.state(Registry.via({:step, model_id})).experiment_mode == :train
    end

    test "a global time-out ends the episode and times out the undecided modules" do
      model_id =
        start_model(
          experiment_mode: :eval,
          learning_modules: [learning_module(:lm_0, terminal: :match), learning_module(:lm_1)],
          sm_to_lm: %{lm_0: [:patch], lm_1: [:patch]}
        )

      {:ok, _, _} = step(model_id)
      :ok = Model.time_out(model_id)

      assert Model.done?(model_id)
      assert_receive {:set_terminal_state, :lm_1, :time_out}
    end
  end

  describe "a step whose module raised" do
    # A coordinator's death is how a run ends when an invariant the policy holds
    # turns out to be false. The caller is handed an exit whose reason is the
    # exception the step was running — and that exception, with the frame that
    # raised it, is what a page can say. "A process exited" is not.
    test "reaches the caller as that exception, with the frame that raised it" do
      model_id = start_model(motor: {RaisingMotor, RaisingMotor.new("the motor disagreed")})

      {exception, stacktrace} =
        try do
          step(model_id)
          flunk("the step was expected to die")
        rescue
          raised -> {raised, __STACKTRACE__}
        end

      assert %RuntimeError{message: "the motor disagreed"} = exception
      assert Enum.any?(stacktrace, &match?({RaisingMotor, _, _, _}, &1))
    end

    # Nothing raised: the model is simply not there. That stays an exit, so a
    # caller cannot mistake it for an exception somebody can fix.
    test "a model that is not running is left as an exit" do
      nowhere = Registry.via({:step, "no-such-model"})

      assert {:noproc, _} =
               catch_exit(Step.step(nowhere, observations(), %{@agent => %{}}, Context.new(1)))
    end
  end

  describe "supervision" do
    # The wiring is not a promise that a module can be replaced. A learning module
    # holds the graph it built; a model that carried on with a fresh one would keep
    # feeding a module that has forgotten everything, which is the failure that
    # looks like success — a run that ends green with nothing learned. So a module
    # that dies ends the model, and the step whose call met the death says so.
    test "a learning module that dies ends the model, and the step after it says why" do
      model_id = start_model()
      assert {:ok, _, _} = step(model_id)

      key = {:learning_module, model_id, :lm_0}
      [{original, _}] = Registry.lookup(key)
      [{model, _}] = Registry.lookup({:model, model_id})

      module_ref = Process.monitor(original)
      model_ref = Process.monitor(model)
      Process.exit(original, :kill)

      assert_receive {:DOWN, ^module_ref, :process, ^original, :killed}
      assert_receive {:DOWN, ^model_ref, :process, ^model, :shutdown}

      # Not replaced and not rebuilt: the next step has nothing to reach, and a
      # caller who holds the model's name is told so rather than stepping a
      # module that has forgotten everything it was given.
      assert {:noproc, _} = catch_exit(step(model_id))
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

  describe "the state a statistics report is read from" do
    test "is what the module says now, not what it was started with" do
      model_id = start_model()

      assert {:ok, [_action], _info} = step(model_id)

      # What the coordinator holds for a module is the state it was started
      # with: the modules are processes and the coordinator keeps their wiring.
      # A report built from it described an episode that had not been taken —
      # every row said `patch_off_object` and nought steps.
      [%{state: at_start}] = Step.state(Registry.via({:step, model_id})).learning_modules
      assert at_start.seen == []

      # Asking the module is what a report needs, and this is the asking.
      [%{state: as_the_episode_left_it}] =
        Step.statistics(Registry.via({:step, model_id})).learning_modules

      assert [%Cmp.Message{}] = as_the_episode_left_it.seen
    end

    test "answers a projection of each module when the report wants one" do
      model_id = start_model()

      assert {:ok, [_action], _info} = step(model_id)

      projected =
        Step.statistics(Registry.via({:step, model_id}), &Map.take(&1, [:id, :mode]))

      assert [%{state: %{id: :lm_0}}] = projected.learning_modules
    end
  end
end
