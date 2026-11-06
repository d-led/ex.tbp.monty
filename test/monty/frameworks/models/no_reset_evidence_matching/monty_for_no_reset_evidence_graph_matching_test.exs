defmodule Monty.Frameworks.Models.NoResetEvidenceMatching.MontyForNoResetEvidenceGraphMatchingTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.NoResetEvidenceMatching.MontyForNoResetEvidenceGraphMatching
  alias Monty.Frameworks.Models.NoResetEvidenceMatching.NoResetEvidenceGraphLM
  alias Monty.Geometry.Rotation
  alias Monty.Runtime.{LearningModuleServer, Registry, Step}

  # Hand-written intent: Monty's own test for this class is the integration one
  # (`tests/integration/frameworks/models/no_reset_evidence_lm_test.py`), which
  # runs two Habitat experiments and asserts that the hypothesis space of the
  # first survives `pre_episode` of the second. These cases state that behaviour
  # against this port's episode boundary, which is `reset_episode_state/1`.

  @module_id "learning_module_0"

  defp module_state(evidence \\ [1.0, 3.0]) do
    {:ok, lm} =
      NoResetEvidenceGraphLM.from_config(%{
        "_target_" =>
          "tbp.monty.frameworks.models.no_reset_evidence_matching.NoResetEvidenceGraphLM",
        "max_match_distance" => 0.01,
        "tolerances" => %{"patch" => %{"rgba" => 0.05}},
        "feature_weights" => %{"patch" => %{"rgba" => 1.0}},
        "learning_module_id" => @module_id
      })

    identity = Rotation.to_matrix(Rotation.identity())
    {:ok, buffer} = FeatureAtLocationBuffer.append(lm.lm.buffer, [observed_at([0.0, 0.0, 0.0])])

    %{
      lm
      | lm: %{
          lm.lm
          | hypotheses: %{
              "mug" =>
                Hypotheses.new(
                  evidence: evidence,
                  locations: [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]],
                  poses: [identity, identity],
                  possible: [true, true]
                )
            },
            possible_matches: ["mug"],
            buffer: buffer
        }
    }
  end

  # One observation the buffer keeps: where the sensor was, and nothing else.
  defp observed_at(location) do
    {:ok, message} =
      Monty.Cmp.Message.new(
        location: location,
        morphological_features: %{},
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: false,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  # A model of one learning module: the server, and the coordinator state that
  # names it. Nothing steps it — the reset is the thing under test.
  defp model(lm) do
    model_id = "model-#{System.unique_integer([:positive])}"

    start_supervised!(
      {LearningModuleServer,
       %{id: @module_id, model_id: model_id, module: NoResetEvidenceGraphLM, state: lm}}
    )

    state = %Step.State{
      model_id: model_id,
      model_class: MontyForNoResetEvidenceGraphMatching,
      learning_modules: [%{id: @module_id, module: NoResetEvidenceGraphLM, state: lm}]
    }

    {state, Registry.via({:learning_module, model_id, @module_id})}
  end

  describe "the reset between two objects" do
    test "keeps what the module believes" do
      {state, server} = model(module_state())
      after_reset = MontyForNoResetEvidenceGraphMatching.reset_episode_state(state)
      assert after_reset.model_id == state.model_id

      held = LearningModuleServer.state(server)

      assert EvidenceGraphLM.graph_memory(held.lm) |> Map.fetch!(:models_in_memory) == %{}
      assert held.lm.possible_matches == ["mug"]
      assert held.lm.hypotheses |> Map.fetch!("mug") |> Hypotheses.evidence() == [1.0, 3.0]
    end

    test "clears what it concluded, and the episode's own counts" do
      {state, server} = model(module_state())
      :ok = LearningModuleServer.set_terminal_state(server, :match)

      after_reset =
        MontyForNoResetEvidenceGraphMatching.reset_episode_state(%{
          state
          | matching_steps: 40,
            done?: true,
            terminal_states: %{@module_id => :match}
        })

      held = LearningModuleServer.state(server)

      assert EvidenceGraphLM.conclusion(held.lm) == nil
      assert after_reset.matching_steps == 0
      assert after_reset.done? == false
      assert after_reset.terminal_states == %{}
    end

    test "empties the buffer of observations it will not read again" do
      {state, server} = model(module_state())
      server_state = LearningModuleServer.state(server)
      assert FeatureAtLocationBuffer.size(server_state.lm.buffer) == 1

      MontyForNoResetEvidenceGraphMatching.reset_episode_state(state)

      emptied = LearningModuleServer.state(server).lm.buffer
      assert FeatureAtLocationBuffer.size(emptied) == 0
      assert emptied.last_location == nil
    end
  end

  describe "the object a new episode is about" do
    test "is named without emptying the record of what the sensor was on" do
      {state, server} = model(module_state())
      :ok = LearningModuleServer.set_stepwise_target(server, "mug")

      MontyForNoResetEvidenceGraphMatching.set_ground_truth_state(
        state,
        %{"object" => "bowl", "quat_rotation" => [1.0, 0.0, 0.0, 0.0]},
        semantic_id_to_label: %{1 => "bowl"}
      )

      held = LearningModuleServer.state(server)

      assert held.lm.primary_target == "bowl"
      assert held.lm.stepwise_targets_list == ["mug"]
    end
  end
end
