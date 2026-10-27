defmodule Monty.Studio.SetupTest do
  use ExUnit.Case, async: true

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
    test "a sensor nothing listens to is called out" do
      setup = setup_for("tutorial/first_experiment")

      assert :sensor_unconnected in warnings(setup)
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
      assert notice.message =~ "CameraSM"
    end

    test "a class this port has written is reported as ported" do
      assert %{status: :implemented, elixir: "Monty.Cmp.Message"} =
               Setup.describe_target("tbp.monty.cmp.Message")
    end

    test "a class Monty ships but this port has not written yet is planned" do
      assert %{status: :planned} =
               Setup.describe_target("tbp.monty.frameworks.models.sensor_modules.CameraSM")
    end

    test "a target the map does not know is reported as unknown, not guessed" do
      assert %{status: :unknown} = Setup.describe_target("tbp.monty.nonexistent.Thing")
    end
  end
end
