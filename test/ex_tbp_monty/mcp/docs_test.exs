defmodule ExTbpMonty.Mcp.DocsTest do
  # The corpus directory is application configuration, so these cannot run
  # beside each other — one test's fixture would be another's documentation.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Docs

  @fixture "test/fixtures/mcp_docs"

  setup do
    previous = Application.get_env(:ex_tbp_monty, :monty_docs_dir)
    Application.put_env(:ex_tbp_monty, :monty_docs_dir, Path.expand(@fixture))
    on_exit(fn -> Application.put_env(:ex_tbp_monty, :monty_docs_dir, previous) end)
  end

  describe "searching the docs" do
    test "answers with the passage and the section it is in, not the whole page" do
      assert {:ok, [hit]} = Docs.search("column voting")

      assert hit.heading == "Cortical Columns"
      assert hit.path == "theory/columns.md"
      assert hit.excerpt =~ "models a whole object"
      assert hit.online == Docs.base_url() <> "columns"
    end

    test "finds a singular word in its plural" do
      assert {:ok, hits} = Docs.search("column")
      assert Enum.any?(hits, &(&1.heading == "Cortical Columns"))
    end

    test "does not offer a comment in a code block as a heading" do
      assert {:ok, hits} = Docs.search("voting")
      refute Enum.any?(hits, &String.contains?(&1.heading, "comment"))
    end

    test "answers nothing rather than something unrelated when no passage has every word" do
      assert {:ok, []} = Docs.search("column quaternion")
    end

    test "refuses a query that is only words with no signal" do
      assert {:error, :empty_query} = Docs.search("what is the")
    end

    test "can be limited to one area" do
      assert {:ok, [hit]} = Docs.search("run.py", area: "how-to")
      assert hit.path == "how-to/run.md"
    end
  end

  describe "reading a page" do
    test "gives its declared title, its published address and its headings" do
      assert {:ok, page} = Docs.read("theory/columns.md")

      assert page.title == "Columns All the Way Down"
      assert page.area == "theory"
      assert page.online == "https://docs.thousandbrains.org/docs/columns"
      assert page.sections == ["Cortical Columns", "Voting"]
    end

    test "will not be talked into reading a file outside the docs" do
      assert {:error, :invalid_path} = Docs.read("../../lib/mix.exs")
      assert {:error, :invalid_path} = Docs.read("/etc/passwd")
      assert {:error, :invalid_path} = Docs.read("theory/columns.txt")
    end

    test "says so when there is no such page" do
      assert {:error, :not_found} = Docs.read("theory/nowhere.md")
    end
  end

  describe "the index" do
    test "lists pages by area" do
      assert Docs.pages() |> Enum.map(& &1.path) == [
               "future-work/voting-improvements.md",
               "future-work/voting-improvements/clean-up-voting.md",
               "future-work/voting-improvements/vote-on-state.md",
               "how-to/run.md",
               "theory/columns.md"
             ]

      assert %{name: "theory", pages: 1} in Docs.areas()
    end
  end
end
