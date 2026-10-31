defmodule ExTbpMonty.Mcp.ToolsTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Mcp.Tools

  describe "the list a client is served" do
    test "every tool is in exactly one family" do
      in_families =
        Tools.families()
        |> Enum.flat_map(fn {_label, tools} -> Enum.map(tools, & &1["name"]) end)
        |> Enum.sort()

      # Both directions: a tool that was added and not placed in a family, and a
      # family that names a tool nobody defines, are both failures here rather
      # than a page that quietly lists the wrong thing.
      assert in_families == Tools.names()
      assert length(in_families) == length(Enum.uniq(in_families))
    end

    test "the families hand over the definitions themselves, not a retelling" do
      defined =
        Tools.definitions()
        |> Map.new(&{&1["name"], &1})

      for {_label, tools} <- Tools.families(), tool <- tools do
        assert tool == defined[tool["name"]]
        assert is_binary(tool["title"]) and tool["title"] != ""
        assert is_map(tool["inputSchema"])
      end
    end

    test "the count is the list's own length" do
      assert Tools.count() == length(Tools.names())
      assert Tools.count() == length(Tools.definitions())
    end

    test "the tools that write are the ones whose annotations say so" do
      writers = Tools.writers() |> Enum.map(& &1["name"]) |> Enum.sort()

      assert writers ==
               ~w(monty_create_experiment monty_delete_runs monty_import_experiment monty_run_experiment)

      for tool <- Tools.definitions() do
        assert tool["annotations"]["readOnlyHint"] == tool["name"] not in writers
      end
    end

    test "docs/mcp.md names every tool, so the document cannot drift" do
      doc = File.read!("docs/mcp.md")

      for name <- Tools.names() do
        assert doc =~ name, "docs/mcp.md does not mention #{name}"
      end
    end
  end
end
