defmodule Monty.Studio.ReadinessTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Readiness

  # Whether an experiment runs here is `Setup`'s answer, read back out. These two
  # are real configs from Monty's own tree: one whose classes this port has
  # written, one built from two it has not.
  describe "reading one experiment" do
    test "an experiment nothing refuses runs here" do
      entry = Readiness.classified("base_config_10distinctobj_dist_agent")

      assert entry.status == :runnable
      assert entry.codes == []
    end

    test "an experiment naming a class nothing here can place names it" do
      entry = Readiness.classified("test/base_config/base_mujoco")

      assert entry.status == :refused
      assert entry.codes == [:unknown_module_class]

      assert "tests.unit.frameworks.models.fakes.sensor_modules.FakeSensorModule" in entry.blocked_by
    end

    # A class the map calls written that still refuses a config is the work too —
    # and it is the cheap kind: the module exists, a capability does not. This one
    # names `graph_1lm`, which is the base `GraphLM` itself: Monty leaves matching
    # to a subclass, and this port raises rather than guess.
    test "a learning module that refuses the config is named as its own blocker" do
      entry = Readiness.classified("tutorial/surf_agent_2obj_train")

      # Which other codes a config earns is its own business; the refusal this
      # case is about is the module's, and the module is named.
      assert :learning_module_not_buildable in entry.codes
      assert entry.blocked_by == ["GraphLM"]
    end
  end

  # Habitat is on its way out upstream (2026-11-08), so a config that needs it is
  # postponed rather than refused: nothing here is missing that anybody means to
  # write. Read for MuJoCo, because that is the world a run would step — the test
  # environment's own default is the stand-in scene, which refuses nothing for a
  # world it does not have.
  describe "an experiment whose world this build does not carry" do
    test "is not planned, not refused" do
      entry = Readiness.classified("test/sensor_module/base", world_simulator: :mujoco)

      assert entry.status == :not_planned
      assert entry.codes == [:world_not_carried]
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
    %{name: name, status: status, world: world, codes: codes, blocked_by: blocked_by}
  end
end
