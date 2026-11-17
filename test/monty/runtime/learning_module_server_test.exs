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

  # A module that tells the coordinator what it believes after every epoch — the
  # mode a lagged run builds (`Monty.Runtime.Step.State.scheduling/1`).
  defp start_reporting_server(model_id, id) do
    spec = %{
      id: id,
      model_id: model_id,
      module: LearningModule,
      state: LearningModule.new(id),
      report_votes: true
    }

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

  describe "saying what it believes" do
    test "a module built to report sends its belief to the coordinator, by epoch", %{
      model_id: model_id
    } do
      # The coordinator is found by name, so a test can be the one that answers
      # to it — the name is the model's own, as in a running model.
      {:ok, _} = Elixir.Registry.register(Monty.Runtime.Registry.registry(), {:step, model_id}, nil)
      server = start_reporting_server(model_id, :lm_0)

      LearningModuleServer.hand_off(server, 4, [Messages.percept()], Context.new(1), "mug")

      assert :ok = LearningModuleServer.await(server, 4)
      # A cast, so the module never waits for the coordinator to listen: the
      # stand-in's vote is its percept count, which tells the report from any
      # other message this module could send.
      assert_receive {:"$gen_cast", {:voted, :lm_0, 4, [count: 1, id: :lm_0]}}
    end

    test "a module built the synchronous way reports nothing", %{model_id: model_id} do
      {:ok, _} = Elixir.Registry.register(Monty.Runtime.Registry.registry(), {:step, model_id}, nil)
      server = start_server(model_id, :lm_0)

      LearningModuleServer.hand_off(server, 0, [Messages.percept()], Context.new(1), "mug")

      assert :ok = LearningModuleServer.await(server, 0)
      refute_receive {:"$gen_cast", {:voted, :lm_0, 0, _vote}}
    end
  end

  describe "votes handed over rather than asked for" do
    test "they wait for the module's next boundary, then apply", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)

      LearningModuleServer.hand_off(server, 0, [Messages.percept()], Context.new(1), "mug")
      assert :ok = LearningModuleServer.await(server, 0)

      # The module is at epoch 0, so epoch 0's votes belong to the boundary it
      # has not crossed yet.
      LearningModuleServer.deliver_votes(server, 0, [:votes_of_epoch_0])
      assert LearningModuleServer.state(server).votes_received == []

      LearningModuleServer.hand_off(server, 1, [Messages.percept()], Context.new(1), "mug")
      assert :ok = LearningModuleServer.await(server, 1)

      assert LearningModuleServer.state(server).votes_received == [:votes_of_epoch_0]
    end

    test "they apply at once when that boundary is already crossed", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)

      LearningModuleServer.hand_off(server, 0, [Messages.percept()], Context.new(1), "mug")
      assert :ok = LearningModuleServer.await(server, 0)
      LearningModuleServer.hand_off(server, 1, [Messages.percept()], Context.new(1), "mug")
      assert :ok = LearningModuleServer.await(server, 1)

      LearningModuleServer.deliver_votes(server, 0, [:late_but_in_time])
      _ = :sys.get_state(server)

      assert LearningModuleServer.state(server).votes_received == [:late_but_in_time]
    end

    test "an epoch's votes are applied once, never twice", %{model_id: model_id} do
      server = start_server(model_id, :lm_0)

      for epoch <- 0..1 do
        LearningModuleServer.hand_off(server, epoch, [Messages.percept()], Context.new(1), "mug")
        assert :ok = LearningModuleServer.await(server, epoch)
      end

      LearningModuleServer.deliver_votes(server, 0, [:once])
      _ = :sys.get_state(server)

      LearningModuleServer.hand_off(server, 2, [Messages.percept()], Context.new(1), "mug")
      assert :ok = LearningModuleServer.await(server, 2)

      assert LearningModuleServer.state(server).votes_received == [:once]
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
