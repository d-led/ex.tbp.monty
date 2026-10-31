defmodule Monty.Frameworks.Loggers.GraphMatchingLoggers.DetailedGraphMatchingLoggerTest do
  @moduledoc """
  The pool a detailed logger builds: every module's buffer, the motor system, and
  the episode numbers a file is keyed by.

  The pool is staked out as a value here (`pool/3`, from the module views a model
  answers), because what a reader of `detailed_run_stats.json` gets is exactly this
  map. The end-to-end path — a config that asks for the detailed logger, a model,
  a file on disk — is exercised by the run's own test.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.GraphMatchingLoggers.DetailedGraphMatchingLogger, as: Logger
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Frameworks.Models.MotorSystem.SurfacePolicyActionDetailsTelemetry

  defmodule KeepsObservations do
    @moduledoc false
    def state_dict(_state), do: %{"raw_observations" => [[1.0, 2.0]]}
  end

  defmodule KeepsNothingToRead do
    @moduledoc false
    def state_dict(_state), do: %{"seen" => 1}
  end

  defmodule Policy do
    @moduledoc false
    defstruct step: 0
    def state_dict(%__MODULE__{step: step}), do: %{step: step}
  end

  defp buffer do
    %{
      FeatureAtLocationBuffer.new()
      | on_object: [1],
        locations: [[0.1, 0.0, 0.0], [0.2, 0.0, 0.0]],
        features: %{"hsv" => [[0.5, 0.2, 0.9], [0.4, 0.2, 0.9]]},
        stats: %{"detected_object" => "mug_graph", "time" => [1, 3]}
    }
  end

  defp lm(overrides \\ []) do
    found = %{buffer: buffer(), stepwise_targets_list: ["mug", "mug"]}
    struct(EvidenceGraphLM, Map.merge(found, Map.new(overrides)))
  end

  defp modules(overrides \\ []) do
    Map.merge(
      %{
        learning_modules: [%{id: :lm_0, module: EvidenceGraphLM, state: lm()}],
        sensor_modules: [],
        motor: nil
      },
      Map.new(overrides)
    )
  end

  defp episode_args, do: %{"train_episodes" => 0, "episode_seed" => 7, "target" => %{}}

  describe "the detailed pool" do
    test "holds the module's buffer: where it went, what it saw, and what came between" do
      pool = Logger.pool(modules(), episode_args(), :train)
      entry = pool["LM_0"]

      assert entry["locations"] == [[0.1, 0.0, 0.0], [0.2, 0.0, 0.0]]
      assert entry["displacements"] == %{}
      assert entry["mode"] == "train"
      assert entry["stepwise_targets_list"] == ["mug", "mug"]

      # A buffer's own stats and features sit beside the episode's arguments, and
      # a buffer stat of the same name wins — the later write, as in Monty.
      assert entry["detected_object"] == "mug_graph"
      assert entry["hsv"] == [[0.5, 0.2, 0.9], [0.4, 0.2, 0.9]]
      assert entry["episode_seed"] == 7
    end

    test "names a module by its position, which is how Monty's handlers expect it" do
      pool =
        Logger.pool(
          modules(
            learning_modules: [
              %{id: :lm_0, module: EvidenceGraphLM, state: lm()},
              %{id: :lm_1, module: EvidenceGraphLM, state: lm()}
            ]
          ),
          episode_args(),
          :eval
        )

      assert Map.keys(pool) |> Enum.sort() == ["LM_0", "LM_1", "motor_system"]
    end

    test "skips a sensor module that kept nothing to read" do
      # Monty writes a sensor module only when its state holds raw observations;
      # a sensor that kept a telemetry map and nothing else adds no entry.
      kept = %{id: :patch, module: KeepsObservations, state: %{}}
      quiet = %{id: :view_finder, module: KeepsNothingToRead, state: %{}}

      assert Logger.pool(modules(sensor_modules: [kept]), episode_args(), :eval)["SM_0"] == %{
               "raw_observations" => [[1.0, 2.0]]
             }

      refute Map.has_key?(
               Logger.pool(modules(sensor_modules: [quiet]), episode_args(), :eval),
               "SM_0"
             )
    end

    test "holds the actions taken, what the policy recorded, and the goals it chose" do
      motor = %MotorSystem{
        policy_selector: %Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector{
          policy: %Policy{step: 3},
          selected_goals: []
        },
        action_sequence: [{[], %{}}],
        telemetry: %SurfacePolicyActionDetailsTelemetry{pc_heading: [:min]}
      }

      pool = Logger.pool(modules(motor: motor), episode_args(), :eval)
      motor_pool = pool["motor_system"]

      assert motor_pool["action_sequence"] == [{[], %{}}]
      assert motor_pool["action_details"]["pc_heading"] == [:min]
      assert motor_pool["policy_selector"]["selected_goals"] == []
      assert motor_pool["policy_selector"]["policy"] == %{step: 3}
    end
  end
end
