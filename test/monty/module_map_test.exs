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

  describe "reading a class path out of a config" do
    test "a Monty class resolves to the Elixir module that holds it" do
      assert {:ok,
              %{
                class: "HabitatEnvironment",
                elixir: "Monty.Simulators.Habitat.Environment.HabitatEnvironment",
                status: :implemented
              }} =
               ModuleMap.resolve("tbp.monty.simulators.habitat.environment.HabitatEnvironment")
    end

    test "a class this port has written comes back implemented" do
      assert {:ok, %{status: :implemented}} = ModuleMap.resolve("tbp.monty.cmp.Message")
    end

    test "a class nobody wrote comes back unknown rather than guessed at" do
      assert {:ok, %{status: :unknown}} =
               ModuleMap.resolve("tbp.monty.frameworks.models.sensor_modules.NotAClass")

      assert :error = ModuleMap.resolve("tbp.monty.no_such_module.Thing")
      assert :error = ModuleMap.resolve("not.a.monty.path")
    end
  end

  describe "an excluded class" do
    test "must say why, the way an excluded module must" do
      assert {:error, problems} =
               verify_with([entry(:planned, [excluded_class("PerceptFilter", nil)])])

      assert problems == [
               "excluded class has no reason: " <>
                 "monty:frameworks/models/sensor_modules.py::PerceptFilter"
             ]
    end

    test "is satisfied by a reason" do
      assert {:ok, _summary} =
               verify_with([
                 entry(:planned, [
                   excluded_class("PerceptFilter", "a Protocol; no runtime behaviour")
                 ])
               ])
    end

    test "needs none of its own when its whole file is excluded" do
      assert {:ok, _summary} = verify_with([entry(:excluded, [excluded_class("Thing", nil)])])
    end
  end

  describe "regenerating the map" do
    # The map is generated, and a generator that treats what it read as a
    # decision makes its own output permanent. Only classes the old map
    # actually excluded are carried; everything else is recomputed from the
    # Python source.
    test "a planned class is not turned into an excluded one" do
      entries = [
        %{
          package: "monty",
          python: "frameworks/models/sensor_modules.py",
          status: :planned,
          classes: [
            %{
              python: "CameraSM",
              status: :planned,
              elixir: "Monty.Frameworks.Models.SensorModules.CameraSM"
            },
            %{
              python: "PerceptFilter",
              status: :excluded,
              elixir: "Monty.Frameworks.Models.SensorModules.PerceptFilter",
              reason: "a Protocol; no runtime behaviour"
            }
          ]
        }
      ]

      decisions = Mix.Tasks.Monty.ModuleMap.Gen.carry_decisions(entries)

      assert %{
               {"monty", "frameworks/models/sensor_modules.py"} => %{
                 excluded_classes: %{"PerceptFilter" => "a Protocol; no runtime behaviour"},
                 status: :planned
               }
             } =
               decisions
    end
  end

  # `verify/1` checks entries against the checkouts; an empty package list
  # keeps these tests about the reasons, not the coverage.
  defp verify_with(entries), do: ModuleMap.verify(entries: entries, packages: [])

  defp entry(status, classes) do
    %{
      package: "monty",
      python: "frameworks/models/sensor_modules.py",
      elixir: "Monty.Frameworks.Models.SensorModules",
      status: status,
      reason: if(status == :excluded, do: "superseded by Monty.Config"),
      classes: classes
    }
  end

  defp excluded_class(name, reason) do
    class = %{
      python: name,
      elixir: "Monty.Frameworks.Models.SensorModules.#{name}",
      status: :excluded
    }

    if reason, do: Map.put(class, :reason, reason), else: class
  end
end
