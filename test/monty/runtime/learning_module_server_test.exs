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
      assert [%Monty.Cmp.Goal{sender_type: :gsg}] = LearningModuleServer.propose_goals(server)
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
end
