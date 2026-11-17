defmodule Monty.Runtime.LearningModuleServerTest do
  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Runtime.{LearningModuleServer, Registry}
  alias Monty.Simulators.Synthetic.LearningModule
  alias Monty.Test.{Messages, MinimalLearningModule}

  setup do
    {:ok, model_id: "learning-#{System.unique_integer([:positive])}"}
  end

  defp start_server(model_id, id, module \\ LearningModule) do
    spec = %{id: id, model_id: model_id, module: module, state: module.new(id)}
    start_supervised!(Supervisor.child_spec({LearningModuleServer, spec}, id: {:learning, id}))
    Registry.via({:learning_module, model_id, id})
  end

  # The recording module takes its options rather than an id, and reports to the
  # process that builds its state — which is this test.
  defp start_recording_server(model_id, id) do
    state = Monty.Test.RecordingLearningModule.new(id: id, notify: self())
    spec = %{id: id, model_id: model_id, module: Monty.Test.RecordingLearningModule, state: state}

    start_supervised!(Supervisor.child_spec({LearningModuleServer, spec}, id: {:learning, id}))

    Registry.via({:learning_module, model_id, id})
  end

  describe "a step" do
    test "keeps the percepts the module was given", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      percept = Messages.percept()

      assert :ok = LearningModuleServer.matching_step(server, [percept], Context.new(1))
      assert LearningModuleServer.state(server).percepts == [percept]
    end

    test "an exploratory step is reported as such to the module", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)

      assert :ok =
               LearningModuleServer.exploratory_step(
                 server,
                 [Messages.percept()],
                 Context.new(1, mode: :exploratory)
               )
    end
  end

  describe "voting" do
    test "a module sends its vote and keeps the votes it receives", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      LearningModuleServer.matching_step(server, [Messages.percept()], Context.new(1))

      assert [count: 1, id: :lm_0] = LearningModuleServer.send_out_vote(server)
      assert :ok = LearningModuleServer.receive_votes(server, [:other_vote])
      assert LearningModuleServer.state(server).votes_received == [:other_vote]
    end
  end

  describe "output and goals" do
    test "a module with percepts emits a top-down output and a goal", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      LearningModuleServer.matching_step(server, [Messages.percept()], Context.new(1))

      assert %Monty.Cmp.Message{sender_type: :lm} = LearningModuleServer.get_output(server)
      assert [%Monty.Cmp.Goal{sender_type: :sm}] = LearningModuleServer.propose_goals(server)
    end
  end

  describe "a step handed over, and waited for" do
    test "the module has done the work once its epoch is reached", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      percept = Messages.percept()

      assert :ok = LearningModuleServer.hand_off(server, 3, [percept], Context.new(1), "mug")

      assert :ok = LearningModuleServer.await(server, 3)
      assert LearningModuleServer.processed_through(server) == 3
      assert LearningModuleServer.state(server).percepts == [percept]
    end

    test "it is named by the object before it reads the percepts", %{model_id: model_id} do
      server = start_recording_server(model_id, :lm_0)
      LearningModuleServer.hand_off(server, 0, [Messages.percept()], Context.new(1), "milka")

      assert :ok = LearningModuleServer.await(server, 0)
      # Mailbox order is the assertion: the name reached the module first.
      assert_receive {:stepwise_target, :lm_0, "milka"}
      assert_receive {:learning_step, :lm_0, [_percept], :matching}
      assert LearningModuleServer.state(server).stepwise_target_object == "milka"
    end

    test "a step not yet handed over is not answered early", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)

      # A wait is a barrier in the data: the epoch has not happened, so the
      # answer has to wait for it. The timeout is the test's, not the module's.
      assert catch_exit(LearningModuleServer.await(server, 7, 30))
      assert LearningModuleServer.processed_through(server) == nil
    end

    test "two steps are taken in the order they were handed over", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      first = Messages.percept()
      second =
        Messages.percept(%{location: [1.0, 0.0, 0.0], sender_id: "patch_1"})

      LearningModuleServer.hand_off(server, 0, [first], Context.new(1), "mug")
      LearningModuleServer.hand_off(server, 1, [second], Context.new(1), "mug")

      assert :ok = LearningModuleServer.await(server, 1)
      assert LearningModuleServer.processed_through(server) == 1
      # Both steps, in the order they were handed over.
      assert LearningModuleServer.state(server).percepts == [first, second]
    end

    test "a module with no input is told so rather than stepped", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)

      LearningModuleServer.hand_off(server, 0, [], Context.new(1), "no_label")

      assert :ok = LearningModuleServer.await(server, 0)
      assert LearningModuleServer.processed_through(server) == 0
      assert LearningModuleServer.state(server).percepts == []
    end
  end

  describe "the behaviour's defaults" do
    test "a minimal module proposes nothing and emits nothing", %{model_id: model_id} do
      server = start_server(model_id, :lm_0, MinimalLearningModule)

      assert LearningModuleServer.propose_goals(server) == []
      assert LearningModuleServer.propose_region(server) == Monty.Cmp.AttentionRegion.empty()
      assert LearningModuleServer.get_output(server) == nil
    end
  end

  describe "reading the module" do
    test "a question is answered against the module's own state", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      percept = Messages.percept()
      LearningModuleServer.matching_step(server, [percept], Context.new(1))

      assert LearningModuleServer.query(server, & &1.percepts) == [percept]
    end

    test "asking leaves the module as it was", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)
      before = :sys.get_state(server)

      assert :no_answer = LearningModuleServer.query(server, fn _state -> :no_answer end)
      assert :sys.get_state(server) == before
    end
  end
end
