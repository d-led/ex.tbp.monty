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

    test "an experiment built from classes this port has not written names them" do
      entry = Readiness.classified("base_infer_cows_large_compositional")

      assert entry.status == :refused
      assert entry.codes == [:modules_not_ported]
      assert "TwoDSensorModule" in entry.blocked_by
    end

    # A class the map calls written that still refuses a config is the work too —
    # and it is the cheap kind: the module exists, a capability does not. This one
    # matches on PPF upstream and on displacement here.
    test "a learning module that refuses the config is named as its own blocker" do
      entry = Readiness.classified("test/graph_learning/ppf_pred")

      assert entry.codes == [:learning_module_not_buildable]
      assert entry.blocked_by == ["DisplacementGraphLM"]
    end
  end

  describe "what the experiments page filters on" do
    test "says yes for what runs and no for anything else" do
      survey =
        Readiness.summarise([
          entry("runs", :runnable, [], []),
          entry("refused", :refused, [:modules_not_ported], ["FeatureGraphLM"]),
          entry("unreadable", :did_not_compose, [:does_not_compose], [])
        ])

      assert Readiness.verdicts(survey) == %{
               "runs" => "yes",
               "refused" => "no",
               "unreadable" => "no"
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
          entry("together", :refused, [:modules_not_ported, :world_not_carried], [
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
  end

  defp entry(name, status, codes, blocked_by) do
    %{name: name, status: status, codes: codes, blocked_by: blocked_by}
  end
end
