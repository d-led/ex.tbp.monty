defmodule Monty.ModuleMapTest do
  use ExUnit.Case, async: true

  alias Monty.ModuleMap

  @moduletag :monty_source

  describe "the naming rule" do
    test "a file becomes the module path it lives at" do
      assert ModuleMap.module_for("Monty", "frameworks/models/buffer.py") ==
               "Monty.Frameworks.Models.Buffer"
    end

    test "a class is appended, unless it repeats the file name" do
      assert ModuleMap.class_module(
               "Monty.Frameworks.Models.EvidenceMatching.Hypotheses",
               "Hypotheses",
               "frameworks/models/evidence_matching/hypotheses.py"
             ) == "Monty.Frameworks.Models.EvidenceMatching.Hypotheses"

      assert ModuleMap.class_module(
               "Monty.Frameworks.Models.EvidenceMatching.LearningModule",
               "EvidenceGraphLM",
               "frameworks/models/evidence_matching/learning_module.py"
             ) == "Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM"
    end

    test "a repeated directory and file name collapse into one segment" do
      assert ModuleMap.module_for("Monty", "frameworks/actions/actions.py") ==
               "Monty.Frameworks.Actions"

      assert ModuleMap.module_for("Monty", "sensor_modules/sensor_module.py") ==
               "Monty.SensorModules.SensorModule"
    end

    test "a top-level file is a first-level namespace" do
      assert ModuleMap.module_for("Monty", "cmp.py") == "Monty.Cmp"
    end

    test "the teleop package gets its own namespace, one segment deep" do
      assert ModuleMap.module_for("Teleop", "controls.py") == "Teleop.Controls"
      assert ModuleMap.module_for("Teleop", "live_plotter.py") == "Teleop.LivePlotter"
    end
  end

  describe "the generated map" do
    test "covers every Python file in both packages" do
      if File.dir?(Path.join(Monty.Config.Source.root(), "src/tbp/monty")) do
        assert {:ok, summary} = ModuleMap.verify()
        assert summary.modules > 100
        assert summary.by_package["monty"] > 100
        assert summary.by_package["teleop"] >= 7
      end
    end

    test "only claims implemented for modules that exist" do
      implemented =
        ModuleMap.load()
        |> Enum.filter(&(&1.status == :implemented))

      assert implemented != []

      for entry <- implemented do
        assert Code.ensure_loaded?(Module.concat(String.split(entry.elixir, "."))),
               "#{entry.python} is marked implemented but #{entry.elixir} does not exist"
      end
    end

    test "every excluded entry says why" do
      for entry <- ModuleMap.load(), entry.status == :excluded do
        refute entry[:reason] in [nil, ""], "#{entry.python} is excluded without a reason"
      end
    end
  end
end
