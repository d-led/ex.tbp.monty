defmodule Monty.RecordingEpisodeTest do
  @moduledoc """
  An episode Monty ran, run again through this port's runtime.

  `test/fixtures/monty_pretrained_episode.jsonl` is one episode of
  `surf_agent_1lm_10distinctobj` recorded while Monty ran it: every percept its
  learning module was given, and what the module concluded. The percepts are
  replayed by a sensor module, so everything else here is the real runtime —
  supervision, the step barriers, the vote round, the coordinator, the episode
  loop — against Monty's own pretrained memory.

  The other replay test (`pretrained_replay_test.exs`) hands observations
  straight to `matching_step/3` and compares evidence step by step, which is how
  the arithmetic is held to Monty's. This one asks the different question: does
  the runtime, deciding for itself what to do with each step, still arrive at
  Monty's conclusion?
  """

  use ExUnit.Case, async: true

  # The episode runs to its own conclusion over a hundred recorded steps, which
  # takes about forty seconds here and over a minute on a CI runner. Trimming
  # the episode would trim the claim, so the test gets the room it needs.
  @moduletag timeout: 300_000

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
  alias Monty.Simulators.Recording
  alias Monty.Simulators.Synthetic.Motor
  alias Monty.Test.MontyRecording

  @recording "test/fixtures/monty_pretrained_episode.jsonl"
  @pretrained "priv/monty/libraries/surf_agent_1lm_10distinctobj.jsonl.gz"
  @channel "patch"
  @agent "agent_id_0"

  # The learning module of the experiment the recording came from
  # (`learning_module/evidence_1lm_nn5_dod0025.yaml`).
  defp learning_module do
    {:ok, lm} =
      EvidenceGraphLM.new(MontyRecording.load_pretrained!(@pretrained),
        max_match_distance: 0.01,
        max_nneighbors: 5,
        hypotheses_updater: BurstSamplingHypothesesUpdater,
        tolerances: %{
          @channel => %{"hsv" => [0.1, 0.2, 0.2], "principal_curvatures_log" => [1.0, 1.0]}
        },
        feature_weights: %{
          @channel => %{
            "hsv" => [2.0, 0.5, 0.5],
            "pose_vectors" => [1.0, 1.0, 1.0],
            "principal_curvatures_log" => [1.0, 1.0]
          }
        },
        x_percent_threshold: 20,
        evidence_threshold_config: "all"
      )

    lm
  end

  # One entry per recorded step: the percept the sensor had for it, or `nil` on
  # the steps it was silent (the agent was moving).
  defp recorded_percepts do
    @recording
    |> MontyRecording.load!()
    |> Enum.map(fn
      [] -> nil
      [percept | _rest] -> percept
    end)
  end

  defp start_model(percepts) do
    model_id = "recording-#{System.unique_integer([:positive])}"

    spec = %{
      model_id: model_id,
      sensor_modules: [
        %{
          id: @channel,
          agent_id: @agent,
          module: Recording.SensorModule,
          state: Recording.SensorModule.new(@channel, percepts)
        }
      ],
      learning_modules: [%{id: :lm_0, module: EvidenceGraphLM, state: learning_module()}],
      sm_to_lm: %{lm_0: [@channel]},
      motor: {Motor, Motor.new()},
      num_exploratory_steps: 12
    }

    start_supervised!(Supervisor.child_spec({Model, spec}, id: model_id))

    model_id
  end

  defp learning_module_state(model_id) do
    LearningModuleServer.state(Registry.via({:learning_module, model_id, :lm_0}))
  end

  describe "replaying an episode Monty ran" do
    test "the runtime reaches the conclusion Monty reached" do
      percepts = recorded_percepts()
      model_id = start_model(percepts)

      # The world is the recording: the sensor has nothing to sense, so the
      # environment only has to tick.
      environment = fn _actions -> {%{}, %{}} end

      result = Episode.run(model_id, environment, mode: :eval, max_steps: length(percepts))

      assert result.done?
      assert result.terminal_states == %{lm_0: :match}
      assert learning_module_state(model_id).detected_object == "mug"
    end
  end
end
