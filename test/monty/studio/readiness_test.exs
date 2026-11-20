defmodule Monty.Studio.ReadinessTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.{Readiness, Setup}

  # Whether an experiment runs here is `Setup`'s answer, read back out. These two
  # are real configs from Monty's own tree: one whose classes this port has
  # written, one built from two it has not.
  describe "reading one experiment" do
    test "an experiment nothing refuses runs here" do
      entry = Readiness.classified("base_config_10distinctobj_dist_agent")

      assert entry.status == :runnable
      assert entry.codes == []
    end

    # Monty's test doubles live under `tests/`, outside the tree the module map
    # covers, so no row can place them. They belong to Monty's test suite rather
    # than to a reader — the port's own tests bring their own — so a config built
    # from them is shelved with the worlds this build does not carry instead of
    # being counted as work somebody has taken on. Its sensor is a double too, so
    # the config also says this port cannot build that sensor; both are facts, and
    # the shelf is decided by the doubles being there at all.
    test "a config built from Monty's test doubles is postponed, not refused" do
      entry = Readiness.classified("test/base_config/base")

      assert entry.status == :not_planned
      assert :test_fixture_class in entry.codes
      assert :sensor_module_not_buildable in entry.codes

      assert "tests.unit.frameworks.models.fakes.sensor_modules.FakeSensorModule" in entry.blocked_by
    end

    # The shelf is decided by the doubles being there at all, not by them being the
    # only thing wrong: a config of fakes says nothing about a world either way, so
    # a second refusal must not drag it back into the backlog. The second reason
    # here is a wire to a module that does not exist, which is a fact about the
    # config rather than about this machine.
    test "is postponed even when the config is also refused for something else" do
      setup =
        Setup.from_text("""
        # @package _global_

        defaults:
          - /monty: graph_exp1000_e3_t3
          - /monty/learning_module: evidence_1lm_nn5_dod003
          - /environment: mujoco_ycb_dist_agent

        experiment:
          _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
          config:
            monty_config:
              learning_modules:
                learning_module_0:
                  _target_: tests.unit.frameworks.models.fakes.learning_modules.FakeLearningModule
              sm_to_agent_dict:
                patch: agent_id_0
              sm_to_lm_matrix:
                - [0, 7]
        """)
        |> elem(1)

      entry = Readiness.classify({"composed_of_fakes", {:ok, setup}})

      # The world this config names is carried, so the refusal clause is the one
      # the shelf has to win against.
      assert entry.world == :mujoco
      assert :test_fixture_class in entry.codes
      assert :connection_index_out_of_range in entry.codes
      assert entry.status == :not_planned
    end

    # The base `GraphLM` is buildable in Monty and trains in a supervised run: an
    # episode hands it the object it saw, and nothing is matched. It refuses only
    # where a match would be asked for, which is Monty's own `NotImplementedError`
    # — so `graph_1lm` is a configuration this port can run, and refusing it here
    # was the port saying more than Monty does.
    test "a bare graph module is not a blocker: the tutorial trains with it" do
      entry = Readiness.classified("tutorial/surf_agent_2obj_train")

      refute :learning_module_not_buildable in entry.codes
      refute "GraphLM" in entry.blocked_by
    end
  end

  # A world this build does not carry is postponed rather than refused: the
  # nearest config to it here runs, so nothing is missing that anybody means to
  # write. A world it *does* carry, read for a config that never asked for it, is
  # refused instead — a MuJoCo scene of an image experiment is not the experiment.
  describe "an experiment whose world this build does not carry" do
    test "is not planned, not refused" do
      # The stream of captures comes from a server this build does not have, and
      # its environment class is unwritten (`SaccadeOnImageFromStreamEnvironment`).
      entry =
        Readiness.classified("world_image_from_stream_on_scanned_model", world_simulator: :image)

      assert entry.status == :not_planned
    end

    test "and a carried world the config never asked for is refused, not postponed" do
      entry = Readiness.classified("world_image_on_scanned_model", world_simulator: :mujoco)

      assert entry.status == :refused
      assert :world_not_carried in entry.codes
    end

    test "the world outranks the classes it would also need" do
      entry = Readiness.classified("tutorial/omniglot_training", world_simulator: :mujoco)

      assert entry.status == :not_planned
      assert "OmniglotEnvironment" in entry.blocked_by
    end
  end

  describe "what the experiments page filters on" do
    test "says yes for what runs, no for what is refused, and its own word for what is postponed" do
      survey =
        Readiness.summarise([
          entry("runs", :runnable, [], []),
          entry("refused", :refused, [:modules_not_ported], ["FeatureGraphLM"]),
          entry("postponed", :not_planned, [:world_not_carried], [], :habitat),
          entry("unreadable", :did_not_compose, [:does_not_compose], [], nil)
        ])

      assert Readiness.labels(survey) == %{
               "runs" => %{ready: "yes", world: "mujoco"},
               "refused" => %{ready: "no", world: "mujoco"},
               "postponed" => %{ready: "not_planned", world: "habitat"},
               "unreadable" => %{ready: "no", world: "other"}
             }
    end

    # A run whose only obstacle is a file is not in the same state as one whose
    # class this port never wrote, and a reader deciding what to do next needs
    # the difference more than the two need one word between them.
    test "says it is waiting when the only thing missing is a download" do
      survey =
        Readiness.summarise([
          entry("needs objects", :refused, [:world_data_missing], []),
          entry("needs memories", :refused, [:no_pretrained_memory], []),
          entry(
            "needs objects and a class",
            :refused,
            [
              :world_data_missing,
              :unknown_module_class
            ],
            ["FakeLearningModule"]
          )
        ])

      labels = Readiness.labels(survey)

      assert labels["needs objects"] == %{ready: "waiting", world: "mujoco"}
      assert labels["needs memories"] == %{ready: "waiting", world: "mujoco"}
      assert labels["needs objects and a class"] == %{ready: "no", world: "mujoco"}
    end
  end

  describe "the ranking" do
    test "counts the experiments a class blocks alone apart from the ones it shares" do
      survey =
        Readiness.summarise([
          entry("first", :refused, [:modules_not_ported], ["FeatureGraphLM"]),
          entry("second", :refused, [:modules_not_ported], ["FeatureGraphLM"]),
          entry("also", :refused, [:modules_not_ported, :world_not_carried], [
            "FeatureGraphLM",
            "TwoDSensorModule"
          ]),
          entry("runs", :runnable, [], [])
        ])

      assert %{class: "FeatureGraphLM", alone: 2, naming: 3, experiments: ["first", "second"]} =
               hd(survey.by_class)
    end

    test "a class that only ever shares ranks below one that blocks alone" do
      survey =
        Readiness.summarise([
          entry("together", :refused, [:modules_not_ported, :learning_module_not_buildable], [
            "FeatureGraphLM",
            "TwoDSensorModule"
          ]),
          entry("alone", :refused, [:learning_module_not_buildable], ["DisplacementGraphLM"])
        ])

      assert Enum.map(survey.by_class, & &1.class) == [
               "DisplacementGraphLM",
               "FeatureGraphLM",
               "TwoDSensorModule"
             ]
    end

    # A class named only by a config whose world is missing is not work anybody has
    # taken on: ranking it would put the Habitat families at the top of a backlog
    # they are not in.
    test "leaves out the classes a postponed experiment names" do
      survey =
        Readiness.summarise([
          entry("postponed", :not_planned, [:world_not_carried, :modules_not_ported], [
            "SaccadeOnImageEnvironment"
          ]),
          entry("refused", :refused, [:modules_not_ported], ["FeatureGraphLM"])
        ])

      assert Enum.map(survey.by_class, & &1.class) == ["FeatureGraphLM"]
      assert survey.not_planned == 1
    end
  end

  defp entry(name, status, codes, blocked_by, world \\ :mujoco) do
    %{
      name: name,
      status: status,
      world: world,
      codes: codes,
      download_offered?: true,
      blocked_by: blocked_by
    }
  end
end
