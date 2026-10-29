defmodule Monty.Studio.SetupTest do
  use ExUnit.Case, async: true

  alias Monty.Experiment.SensorModule.ExperimentSensorModule
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.SensorModules.{CameraSM, FeatureChangeFilter}
  alias Monty.SensorModules.SensorModule
  alias Monty.Simulators.Synthetic
  alias Monty.Studio.{Finding, Setup}

  # The four connectivity rules below are Monty's own: `MontyBase.__init__`
  # refuses to build a model that breaks them. Each test says what Monty says,
  # in the same order, and builds the config from Monty's groups so the fixture
  # is a real config rather than a map shaped like one.

  defp setup_for(name), do: elem(Setup.from_experiment(name), 1)

  # `config:` with nothing under it would wipe the groups' `monty_config` on the
  # way through the composer, which is a fixture bug and not the thing under
  # test, so it is only written when there is something to write.
  defp config_with(groups, config) do
    defaults = Enum.map_join(groups, "\n", fn {group, option} -> "  - /#{group}: #{option}" end)

    body =
      case config do
        empty when empty == %{} ->
          ""

        config ->
          "  config:\n" <>
            Enum.map_join(config, "\n", fn {key, value} -> "    #{key}: #{value}" end)
      end

    """
    # @package _global_

    defaults:
    #{defaults}

    experiment:
      _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
    #{body}
    """
  end

  defp setup_from(groups, config \\ %{}) do
    {:ok, setup} = Setup.from_text(config_with(groups, config))
    setup
  end

  defp errors(setup), do: setup.findings |> Finding.at(:error) |> Enum.map(& &1.code)
  defp warnings(setup), do: setup.findings |> Finding.at(:warning) |> Enum.map(& &1.code)

  defp finding(setup, code) do
    setup.findings
    |> Enum.find(&(&1.code == code)) ||
      flunk("no finding #{inspect(code)}; got #{inspect(Enum.map(setup.findings, & &1.code))}")
  end

  @base %{
    "monty" => "graph_exp1000_e3_t3",
    "monty/motor_system_config" => "distant_5",
    "monty/learning_module" => "evidence_1lm_nn5_dod003",
    "monty/sensor_module" => "camera_dist_delta_salience",
    "monty/connectivity" => "1lm_1sm",
    "environment" => "habitat_ycb_dist_agent_semantics0",
    "termination" => "any1_objectrecognition_t1000_e500_tot6000",
    "logging" => "silent_warning_train",
    "telemetry" => "warning"
  }

  describe "reading a real experiment" do
    test "Monty's one-sensor, one-module experiment reads as one of each" do
      setup = setup_for("tutorial/first_experiment")

      assert Enum.map(setup.sensors, & &1.id) == ["patch", "view_finder"]
      assert Enum.map(setup.learning_modules, & &1.id) == ["learning_module_0"]
      assert Enum.any?(setup.connections, &(&1.kind == :sensor_input))
    end

    test "a hierarchy reads as votes between learning modules" do
      setup = setup_for("randrot_noise_10distinctobj_5lms_dist_agent")

      assert length(setup.learning_modules) == 5

      assert setup.connections
             |> Enum.filter(&(&1.kind == :vote))
             |> length() == 20
    end

    test "the environment is the simulator plus the interface that makes episodes" do
      setup = setup_for("tutorial/first_experiment")

      assert setup.environment.module.class
      assert setup.environment.interface.class
      assert setup.environment.objects == ["coneSolid"]
    end

    test "the agent starts where the experiment starts it, with its sensors on it" do
      setup = setup_for("base_10simobj_surf_agent")

      assert setup.scene.agent.position == [0.0, 1.5, 0.1]
      assert setup.scene.sensors["patch"].position == [0.0, 0.0, 0.0]
      assert setup.scene.sensors["view_finder"].position == [0.0, 0.0, 0.03]
      assert setup.scene.objects == [%{name: "coneSolid", position: [0.0, 1.5, -0.1]}]
    end

    test "each sensor's camera is the one the experiment's agent declares" do
      setup = setup_for("base_10simobj_surf_agent")

      assert setup.cameras["patch"] == [resolution: {64, 64}, zoom: 10.0, hfov: 90.0]
      assert setup.cameras["view_finder"] == [resolution: {64, 64}, zoom: 1.0, hfov: 90.0]
    end

    test "a config that declares no agent has no cameras to render through" do
      setup = Setup.new(%{"experiment" => %{"config" => %{}}})

      assert setup.cameras == %{}
    end

    test "a config Monty ships is not reported as broken" do
      setup = setup_for("tutorial/first_experiment")

      assert Setup.valid?(setup), "expected no errors, got #{inspect(errors(setup))}"
    end
  end

  describe "the connectivity Monty insists on" do
    test "a model without sm_to_lm_matrix is refused" do
      setup = setup_from(Map.delete(@base, "monty/connectivity"))

      assert :sm_to_lm_matrix_missing in errors(setup)
    end

    test "the matrix needs a row per learning module" do
      # Two learning modules, wired as if there were one.
      setup = setup_from(Map.put(@base, "monty/learning_module", "displacement_5lm"))

      assert :learning_module_count_mismatch in errors(setup)
    end

    test "every sensor module needs exactly one agent" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /monty/sensor_module: camera_dist_delta_salience

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sm_to_agent_dict:
                patch: agent_id_0
              sm_to_lm_matrix:
                - [0]
        """)
        |> elem(1)

      assert :sensor_agent_mapping_mismatch in errors(setup)
    end

    test "a wire to a module that does not exist is reported, not crashed on" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /monty/sensor_module: camera_dist_delta_salience

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sm_to_agent_dict:
                patch: agent_id_0
                view_finder: agent_id_0
              sm_to_lm_matrix:
                - [0, 7]
        """)
        |> elem(1)

      assert :connection_index_out_of_range in errors(setup)
    end
  end

  describe "the mistakes Monty would only find later" do
    test "a sensor no learning module matches on is explained, not raised as a mistake" do
      setup = setup_for("tutorial/first_experiment")

      assert %Finding{level: :info, message: message, where: "view_finder"} =
               finding(setup, :sensor_not_matched)

      assert message =~ "feeds no learning module"
      refute :sensor_unconnected in warnings(setup)
    end

    test "a feature the sensor does not produce is called out" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /monty/sensor_module: camera_dist_delta_salience
          - /monty/connectivity: 1lm_1sm

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              sm_to_agent_dict:
                patch: agent_id_0
                view_finder: agent_id_0
              sm_to_lm_matrix:
                - [0]
              learning_modules:
                learning_module_0:
                  _target_: tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM
                  feature_weights:
                    patch:
                      not_a_feature: 1
              sensor_modules:
                sensor_module_0:
                  _target_: tbp.monty.frameworks.models.sensor_modules.CameraSM
                  sensor_module_id: patch
                  features:
                    - hsv
                sensor_module_1:
                  _target_: tbp.monty.frameworks.models.sensor_modules.CameraSM
                  sensor_module_id: view_finder
                  features:
                    - hsv
        """)
        |> elem(1)

      assert :feature_not_provided in warnings(setup)
    end
  end

  describe "what is ported" do
    test "one line says what is missing, not one line per module" do
      setup = setup_for("tutorial/first_experiment")

      notices = for %{code: :modules_not_ported} = finding <- setup.findings, do: finding

      assert [notice] = notices
      assert notice.message =~ "not ported yet"
      assert notice.message =~ "HabitatEnvironment"
    end

    test "a class this port has written is reported as ported" do
      assert %{status: :implemented, elixir: "Monty.Cmp.Message"} =
               Setup.describe_target("tbp.monty.cmp.Message")
    end

    test "a class Monty ships but this port has not written yet is planned" do
      # Habitat, the simulator Monty's own runs are embedded in.
      assert %{status: :planned} =
               Setup.describe_target(
                 "tbp.monty.simulators.habitat.environment.HabitatEnvironment"
               )
    end

    test "a target the map does not know is reported as unknown, not guessed" do
      assert %{status: :unknown} = Setup.describe_target("tbp.monty.nonexistent.Thing")
    end
  end

  describe "what a run cannot yet do" do
    test "says so when the config asks for a goal generator" do
      setup = setup_from(@base)

      finding = finding(setup, :goal_generator_not_ported)

      assert finding.level == :warning
      assert finding.message =~ "explores without goals"
    end
  end

  describe "the model a run starts" do
    test "uses the ported module when the config targets one" do
      setup = setup_from(@base)

      spec = Setup.model_spec(setup, "model_0")

      assert [%{module: EvidenceGraphLM, state: %EvidenceGraphLM{} = lm}] = spec.learning_modules

      # Built from the experiment's own numbers, down to the memory it learns
      # into: those are what make this a run of this experiment.
      assert lm.max_match_distance == 0.01
      assert lm.graph_memory.object_model_options[:max_size] == 0.3
    end

    test "runs the sensor class the config targets, when this port has it" do
      spec = @base |> setup_from() |> Setup.model_spec("model_0")

      assert %{module: CameraSM, state: %CameraSM{} = sensor} =
               Enum.find(spec.sensor_modules, &(&1.id == "patch"))

      # Built from the config's own keys: the features it declared and the filter
      # it asked for.
      assert sensor.features == [
               "pose_vectors",
               "pose_fully_defined",
               "on_object",
               "object_coverage",
               "hsv",
               "principal_curvatures_log"
             ]

      assert {FeatureChangeFilter, %FeatureChangeFilter{}} = sensor.filter
    end

    test "runs each sensor's own class when the config names two of them" do
      # Monty's surf experiments: a patch that is a `CameraSM`, and a view finder
      # that is a transform-pipeline `ExperimentSensorModule` — a camera that
      # measures the scene for the motor system and sends no percept at all.
      spec = "base_10simobj_surf_agent" |> setup_for() |> Setup.model_spec("model_0")

      assert %{module: CameraSM} =
               Enum.find(spec.sensor_modules, &(&1.id == "patch"))

      assert %{module: ExperimentSensorModule, state: %SensorModule{transforms: []}} =
               Enum.find(spec.sensor_modules, &(&1.id == "view_finder"))
    end

    test "runs the stand-in for a sensor class this port has not written" do
      # The 2D sensor module of Monty's three-sensor configurations is still to
      # come, so that config gets the stand-in rather than a camera that quietly
      # behaves as if it were one.
      setup = setup_from(%{@base | "monty/sensor_module" => "3sm_2d3d_dist"})

      spec = Setup.model_spec(setup, "model_0")

      assert Enum.any?(spec.sensor_modules, &match?(%{module: Synthetic.SensorModule}, &1))
    end

    test "falls back to the stand-in for a module this port has not written" do
      # A displacement module: matching on point-pair features, which is not
      # ported, so the stand-in runs and says so by being one.
      setup = setup_from(%{@base | "monty/learning_module" => "displacement_1lm"})

      spec = Setup.model_spec(setup, "model_0")

      assert [%{module: Synthetic.LearningModule}] = spec.learning_modules
    end
  end
end
