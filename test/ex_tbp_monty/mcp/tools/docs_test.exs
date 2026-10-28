defmodule ExTbpMonty.Mcp.Tools.DocsTest do
  # The corpus directory is application configuration, so these cannot run
  # beside each other — one test's fixture would be another's documentation.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Tools.Docs

  setup do
    previous = Application.get_env(:ex_tbp_monty, :monty_docs_dir)
    Application.put_env(:ex_tbp_monty, :monty_docs_dir, Path.expand("test/fixtures/mcp_docs"))
    on_exit(fn -> Application.put_env(:ex_tbp_monty, :monty_docs_dir, previous) end)
  end

  describe "monty_search_docs" do
    test "answers with passages, and says where each one is published" do
      assert {:ok, %{text: text, structured: %{query: "column voting", hits: [hit]}}} =
               Docs.search(%{"query" => "column voting"}, %{})

      assert hit.heading == "Cortical Columns"
      assert text =~ "Cortical Columns"
      assert text =~ "theory/columns.md"
    end

    test "says so, and what to try instead, when nothing has all of the words" do
      assert {:ok, %{text: text, structured: %{hits: []}}} =
               Docs.search(%{"query" => "column quaternion"}, %{})

      assert text =~ "No passage of Monty's docs has all of `column quaternion`"
    end

    test "turns a query of nothing but stop words into advice" do
      assert Docs.search(%{"query" => "what is the"}, %{}) ==
               {:error, "`query` needs a word that is not a stop word."}
    end

    test "asks for the query it needs" do
      assert Docs.search(%{}, %{}) == {:error, "`query` is required."}
    end
  end

  describe "monty_docs_index" do
    test "lists the areas and the pages" do
      assert {:ok, %{structured: %{areas: areas, pages: pages}}} = Docs.index(%{}, %{})

      assert Enum.any?(areas, &(&1.name == "theory"))
      assert Enum.any?(pages, &(&1.path == "theory/columns.md"))
    end

    test "narrows to one area when asked" do
      assert {:ok, %{structured: %{pages: pages}}} = Docs.index(%{"area" => "how-to"}, %{})

      assert Enum.any?(pages, &(&1.path == "how-to/run.md"))
      assert Enum.all?(pages, &(&1.area == "how-to"))
    end

    test "names the areas that exist when asked for one that does not" do
      assert {:error, message} = Docs.index(%{"area" => "theory-of-everything"}, %{})

      assert message =~ "There is no `theory-of-everything` area"
      assert message =~ "theory"
    end
  end
end
