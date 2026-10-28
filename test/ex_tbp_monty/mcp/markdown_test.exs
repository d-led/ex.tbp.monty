defmodule ExTbpMonty.Mcp.MarkdownTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Mcp.Markdown

  describe "a page with front matter" do
    test "its fields are read and its body is what remains" do
      {meta, body} =
        Markdown.frontmatter("---\ntitle: Voting\ndescription: a task\n---\n\n# Voting\n")

      assert meta["title"] == "Voting"
      assert meta["description"] == "a task"
      assert String.starts_with?(body, "\n# Voting")
    end

    test "a page without front matter keeps all of its text" do
      assert {%{}, "# Running"} = Markdown.frontmatter("# Running")
    end
  end

  describe "a page's sections" do
    test "are split at its headings, with the introduction unnamed" do
      sections = Markdown.sections("An intro.\n\n# One\nfirst\n\n## Two\nsecond\n")

      assert sections == [
               {nil, "An intro.\n"},
               {"One", "first\n"},
               {"Two", "second\n"}
             ]
    end

    test "do not split at a comment inside a code block" do
      markdown = "# Setup\n\n```python\n# set the seed\nseed = 0\n```\n"

      assert [_introduction, {"Setup", body}] = Markdown.sections(markdown)
      assert body =~ "seed = 0"
    end

    test "name the headings a reader can jump to" do
      assert Markdown.headings("# One\n\n## Two\n") == ["One", "Two"]
    end
  end
end
