defmodule ExTbpMonty.Mcp.Tools.DocsTest do
  # The site is application configuration, so these read one stub at a time.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Test.FakeDocsHttp
  alias ExTbpMonty.Mcp.Tools.Docs

  @site "https://docs.thousandbrains.org"
  @search @site <> "/thousandbrainsproject/api-next/v2/search"
  @index @site <> "/llms.txt"

  @index_text """
  ## Guides: How Monty Works
  - [Learning Modules](https://docs.thousandbrains.org/docs/learning-modules.md)
  - [Cortical Messaging Protocol](https://docs.thousandbrains.org/docs/cortical-messaging-protocol.md)

  ## Guides: How to Use Monty
  - [Getting Started](https://docs.thousandbrains.org/docs/getting-started.md): How to get the code running.
  """

  @hits """
  {
    "total": 1,
    "data": [
      {
        "url": {"full": "https://docs.thousandbrains.org/v0.56/docs/cortical-messaging-protocol"},
        "title": "Cortical Messaging Protocol",
        "breadcrumbs": [],
        "highlights": [{"value": "Columns vote with evidence.", "type": "text"}],
        "slug": "cortical-messaging-protocol",
        "section": "guides"
      }
    ]
  }
  """

  setup do
    FakeDocsHttp.serve(%{
      @index => @index_text,
      (@search <> "?query=voting&per_page=6") => @hits,
      (@search <> "?query=quaternion&per_page=6") => ~s({"total": 0, "data": []})
    })
  end

  describe "monty_search_docs" do
    test "answers with the page, where it is published and the passage that matched" do
      assert {:ok, %{text: text, structured: %{query: "voting", hits: [hit]}}} =
               Docs.search(%{"query" => "voting"}, %{})

      assert hit.slug == "cortical-messaging-protocol"
      assert text =~ "Cortical Messaging Protocol"
      assert text =~ @site <> "/v0.56/docs/cortical-messaging-protocol"
      assert text =~ "`cortical-messaging-protocol`"
    end

    test "says so, and where else to look, when the site has no page for the words" do
      assert {:ok, %{text: text, structured: %{hits: []}}} =
               Docs.search(%{"query" => "quaternion"}, %{})

      assert text =~ "no page matching `quaternion`"
      assert text =~ "monty_docs_index"
    end

    test "names the areas that exist when asked for one that does not" do
      assert {:error, message} = Docs.search(%{"query" => "voting", "area" => "theory"}, %{})

      assert message =~ "There is no `theory` area"
      assert message =~ "how-monty-works"
    end

    test "says the site could not be reached, and that every docs tool is affected" do
      FakeDocsHttp.serve(%{(@search <> "?query=voting&per_page=6") => {:error, :timeout}})

      assert {:error, message} = Docs.search(%{"query" => "voting"}, %{})
      assert message =~ "could not be reached"
      assert message =~ "Try again"
    end

    test "asks for the query it needs" do
      assert Docs.search(%{}, %{}) == {:error, "`query` is required."}
    end
  end

  describe "monty_read_doc" do
    test "gives the page whole, with its headings and the address to cite" do
      FakeDocsHttp.serve(%{
        (@site <> "/docs/learning-modules.md") =>
          "# Learning Modules\n\nA learning module models an object.\n\n## Evidence\n\nMatching.\n"
      })

      assert {:ok, %{text: text, structured: page}} =
               Docs.read(%{"slug" => "learning-modules"}, %{})

      assert page.slug == "learning-modules"
      assert page.online == @site <> "/docs/learning-modules"
      assert page.sections == ["Learning Modules", "Evidence"]
      assert page.markdown =~ "models an object"
      assert text =~ "# Learning Modules"
    end

    test "says a page is missing rather than failing" do
      assert {:error, message} = Docs.read(%{"slug" => "no-such-page"}, %{})
      assert message =~ "There is no page `no-such-page`"
    end

    test "explains what a slug is when it is handed something else" do
      assert {:error, message} =
               Docs.read(%{"slug" => "how-monty-works/learning-modules.md"}, %{})

      assert message =~ "not a page slug"
      assert message =~ "monty_docs_index"
    end

    test "asks for the slug it needs" do
      assert Docs.read(%{}, %{}) == {:error, "`slug` is required."}
    end
  end

  describe "monty_docs_map" do
    test "hands back the site's index verbatim, and counts the pages listed in it" do
      assert {:ok, %{text: text, structured: %{area: nil, pages: 3}}} = Docs.map(%{}, %{})

      assert text =~ "## Guides: How to Use Monty"
      assert text =~ "getting-started"
    end

    test "narrows to one area when asked" do
      assert {:ok, %{text: text, structured: %{area: "how-to-use-monty"}}} =
               Docs.map(%{"area" => "how-to-use-monty"}, %{})

      assert text =~ "getting-started"
      refute text =~ "learning-modules"
    end

    test "names the areas that exist when asked for one that does not" do
      assert {:error, message} = Docs.map(%{"area" => "theory"}, %{})

      assert message =~ "There is no `theory` area"
      assert message =~ "how-monty-works"
    end

    test "says the site could not be reached when the index does not answer" do
      FakeDocsHttp.serve(%{@index => {500, "nope"}})

      assert {:error, message} = Docs.map(%{}, %{})
      assert message =~ "could not be reached"
    end
  end

  describe "monty_docs_index" do
    test "lists the areas and the pages" do
      assert {:ok, %{structured: %{areas: areas, pages: pages}}} = Docs.index(%{}, %{})

      assert Enum.any?(areas, &(&1.name == "how-monty-works"))
      assert Enum.any?(pages, &(&1.slug == "learning-modules"))
    end

    test "narrows to one area when asked" do
      assert {:ok, %{structured: %{pages: pages}}} =
               Docs.index(%{"area" => "how-to-use-monty"}, %{})

      assert [%{slug: "getting-started", area: "how-to-use-monty"}] = pages
    end

    test "names the areas that exist when asked for one that does not" do
      assert {:error, message} = Docs.index(%{"area" => "theory-of-everything"}, %{})

      assert message =~ "There is no `theory-of-everything` area"
      assert message =~ "how-monty-works"
    end

    test "says the site could not be reached when the index does not answer" do
      FakeDocsHttp.serve(%{@index => {500, "nope"}})

      assert {:error, message} = Docs.index(%{}, %{})
      assert message =~ "could not be reached"
    end
  end
end
