defmodule ExTbpMonty.Mcp.Tools.PortTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Mcp.Tools.Port

  @implemented "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM"
  @planned "tbp.monty.simulators.habitat.environment.HabitatEnvironment"

  describe "monty_lookup_module" do
    test "names the Elixir module a Python class became, and the classes in its file" do
      assert {:ok, %{text: text, structured: entry}} =
               Port.lookup(%{"target" => @implemented}, %{})

      assert entry.status == :implemented
      assert text =~ entry.elixir
      assert text =~ "→ `#{entry.elixir}` — implemented"
      assert text =~ "EvidenceGraphLM"
    end

    test "says when a class is planned rather than promising it exists" do
      assert {:ok, %{text: text, structured: %{status: :planned}}} =
               Port.lookup(%{"target" => @planned}, %{})

      assert text =~ "planned"
    end

    test "asks for the target it needs" do
      assert Port.lookup(%{}, %{}) == {:error, "`target` is required."}
    end

    test "says nothing matches a target it does not know" do
      assert {:error, message} = Port.lookup(%{"target" => "tbp.monty.no.Such"}, %{})

      assert message =~ "no.Such"
    end
  end

  describe "monty_port_status" do
    test "counts what exists, what is planned and what is left out" do
      assert {:ok, %{text: text, structured: %{summary: summary}}} = Port.status(%{}, %{})

      assert summary.modules > 0
      assert text =~ "#{summary.implemented} of #{summary.modules} modules implemented"
    end
  end
end
