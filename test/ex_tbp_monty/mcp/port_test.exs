defmodule ExTbpMonty.Mcp.PortTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Mcp.Port

  @implemented "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM"
  @planned "tbp.monty.frameworks.models.sensor_modules.CameraSM"

  describe "looking up a module" do
    test "a class Monty's configs name resolves to the Elixir module and its verdict" do
      assert {:ok, entry} = Port.lookup(@implemented)

      assert entry.elixir ==
               "Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM"

      assert entry.status == :implemented
      assert entry.python == "frameworks/models/evidence_matching/learning_module.py"
    end

    test "a module that is not ported says so rather than promising it exists" do
      assert {:ok, %{status: :planned, elixir: "Monty.Frameworks.Models.SensorModules.CameraSM"}} =
               Port.lookup(@planned)
    end

    test "the file a module lives in resolves to the file's own module" do
      assert {:ok, entry} = Port.lookup("src/tbp/monty/frameworks/models/sensor_modules.py")

      assert entry.python == "frameworks/models/sensor_modules.py"
      assert entry.elixir == "Monty.Frameworks.Models.SensorModules"
      assert Enum.any?(entry.classes, &(&1.python == "CameraSM"))
    end

    test "the Elixir module resolves back to the Python it came from" do
      assert {:ok, entry} = Port.lookup("Monty.Frameworks.Models.SensorModules.CameraSM")
      assert entry.class == "CameraSM"
      assert entry.python == "frameworks/models/sensor_modules.py"
    end

    test "anything else is an error that says what a target looks like" do
      assert {:error, message} = Port.lookup("nonsense")
      assert message =~ "tbp.monty"
    end

    test "a class the map does not list is unknown, not invented" do
      assert {:ok, %{status: :unknown}} =
               Port.lookup("tbp.monty.frameworks.models.sensor_modules.NoSuchSensor")
    end
  end

  describe "the port's status" do
    test "counts what exists here and lists what does not" do
      status = Port.status()

      assert status.summary.modules > 100
      assert status.summary.implemented > 0
      assert Enum.any?(status.planned, &(&1.elixir == "Monty.Attention.AttentionSystem"))
    end
  end

  describe "the code a page refers to" do
    test "both spellings of a reference are resolved" do
      text = """
      See src/tbp/monty/frameworks/models/sensor_modules.py and
      tbp.monty.frameworks.models.sensor_modules.CameraSM for the details.
      """

      modules = Port.referenced(text)

      assert Enum.any?(modules, &(&1.elixir == "Monty.Frameworks.Models.SensorModules"))
      assert Enum.any?(modules, &(&1.elixir == "Monty.Frameworks.Models.SensorModules.CameraSM"))
    end

    test "a page with no references to code yields none" do
      assert Port.referenced("A paragraph about columns and votes.") == []
    end
  end
end
