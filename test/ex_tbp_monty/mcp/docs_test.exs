defmodule ExTbpMonty.Mcp.DocsTest do
  # The site the tools talk to is application configuration, so these read one
  # stub at a time.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Docs
  alias ExTbpMonty.Mcp.Test.FakeDocsHttp
  alias Monty.Test.Tmp

  @site "https://docs.thousandbrains.org"
  @search @site <> "/thousandbrainsproject/api-next/v2/search"
  @index @site <> "/llms.txt"
  @protocol @site <> "/docs/cortical-messaging-protocol.md"

  @index_text """
  # Thousand Brains Project Documentation

  > Documentation for Thousand Brains Project

  ## Guides: How Monty Works
  - [Learning Modules](https://docs.thousandbrains.org/docs/learning-modules.md)
    - [Evidence-Based Learning Module](https://docs.thousandbrains.org/docs/evidence-based-learning-module.md): Learns by matching evidence.
  - [Cortical Messaging Protocol](https://docs.thousandbrains.org/docs/cortical-messaging-protocol.md)

  ## Guides: How to Use Monty
  - [Getting Started](https://docs.thousandbrains.org/docs/getting-started.md): How to get the code running.
  """

  @protocol_result """
  {
    "total": 1,
    "page": 1,
    "per_page": 6,
    "data": [
      {
        "url": {"full": "https://docs.thousandbrains.org/v0.56/docs/cortical-messaging-protocol"},
        "title": "Cortical Messaging Protocol",
        "breadcrumbs": [],
        "highlights": [
          {"value": "…to make Monty's ", "type": "text"},
          {"value": "voting", "type": "hit"},
          {"value": " algorithm better. Help Us Make This Page Better…", "type": "text"}
        ],
        "slug": "cortical-messaging-protocol",
        "section": "guides",
        "version": "v0.56"
      }
    ]
  }
  """

  @protocol_page """
  ---
  updatedAt: 2026-07-15T10:14:26.000Z
  agentTools:
    projectIndex: https://docs.thousandbrains.org/llms.txt
  ---

  # Cortical Messaging Protocol

  A message is a set of features at a location.

  ## Voting

  Columns vote with evidence.
  """

  setup do
    FakeDocsHttp.serve(%{
      @index => @index_text,
      (@search <> "?query=column+voting&per_page=6") => @protocol_result,
      @protocol => @protocol_page
    })
  end

  describe "searching the site" do
    test "answers with the page, the address it is published at, and the matched passage" do
      assert {:ok, [hit]} = Docs.search("column voting", limit: 6)

      assert hit.slug == "cortical-messaging-protocol"
      assert hit.title == "Cortical Messaging Protocol"
      assert hit.online == @site <> "/v0.56/docs/cortical-messaging-protocol"

      assert hit.excerpt ==
               "…to make Monty's voting algorithm better. Help Us Make This Page Better…"
    end

    test "keeps only the pages of the area that was asked for" do
      assert {:ok, [%{slug: "cortical-messaging-protocol"}]} =
               Docs.search("column voting", limit: 6, area: "how-monty-works")

      assert {:ok, []} = Docs.search("column voting", limit: 6, area: "how-to-use-monty")
    end

    test "names the areas when the one asked for does not exist" do
      assert {:error, {:unknown_area, "community", areas}} =
               Docs.search("column voting", limit: 6, area: "community")

      assert "how-monty-works" in areas
      assert "how-to-use-monty" in areas
    end

    test "asks the site which version to answer from when one is configured" do
      Tmp.app_env(:docs_version, "0.56")

      FakeDocsHttp.serve(%{
        (@search <> "?query=column+voting&per_page=6&version=0.56") => @protocol_result
      })

      assert {:ok, [%{slug: "cortical-messaging-protocol"}]} =
               Docs.search("column voting", limit: 6)
    end

    test "drops a result the site gave no page name for" do
      FakeDocsHttp.serve(%{
        (@search <> "?query=column+voting&per_page=6") => ~s({"data": [{"title": "No name"}]})
      })

      assert {:ok, []} = Docs.search("column voting", limit: 6)
    end

    test "says the site did not answer, rather than raising, when the request fails" do
      FakeDocsHttp.serve(%{
        (@search <> "?query=column+voting&per_page=6") => {:error, :econnrefused}
      })

      assert {:error, :unreachable} = Docs.search("column voting", limit: 6)
    end

    test "treats a body that is not an answer as the site being unavailable" do
      FakeDocsHttp.serve(%{(@search <> "?query=column+voting&per_page=6") => "<html>oops</html>"})

      assert {:error, :unreachable} = Docs.search("column voting", limit: 6)
    end
  end

  describe "reading a page" do
    test "is the page's markdown, its title, its headings and its address" do
      assert {:ok, page} = Docs.read("cortical-messaging-protocol")

      assert page.title == "Cortical Messaging Protocol"
      assert page.online == @site <> "/docs/cortical-messaging-protocol"
      assert page.sections == ["Cortical Messaging Protocol", "Voting"]
      assert page.markdown =~ "Columns vote with evidence."
      refute page.markdown =~ "updatedAt"
    end

    test "accepts the address's file name, which is how a reader copies it" do
      assert {:ok, %{slug: "cortical-messaging-protocol"}} =
               Docs.read("cortical-messaging-protocol.md")
    end

    test "refuses anything that is not a page slug" do
      assert {:error, :invalid_slug} = Docs.read("../../lib/mix.exs")
      assert {:error, :invalid_slug} = Docs.read("/etc/passwd")
      assert {:error, :invalid_slug} = Docs.read("Theory/Columns")
      assert {:error, :invalid_slug} = Docs.read("")
    end

    test "says a page is not there when the site does not have it" do
      assert {:error, :not_found} = Docs.read("no-such-page")
    end

    test "says the site did not answer, rather than raising" do
      FakeDocsHttp.serve(%{@protocol => {:error, :timeout}})

      assert {:error, :unreachable} = Docs.read("cortical-messaging-protocol")
    end
  end

  describe "the index" do
    test "is the site's own page list, grouped into its areas" do
      assert {:ok, %{areas: areas, pages: pages}} = Docs.index()

      assert %{name: "how-monty-works", pages: 3} in areas
      assert %{name: "how-to-use-monty", pages: 1} in areas

      getting_started = Enum.find(pages, &(&1.slug == "getting-started"))

      assert getting_started.title == "Getting Started"
      assert getting_started.area == "how-to-use-monty"
      assert getting_started.description == "How to get the code running."
    end

    test "counts a page once when the site lists it under two headings" do
      FakeDocsHttp.serve(%{
        @index => """
        ## Guides: How Monty Works
        - [Learning Modules](https://docs.thousandbrains.org/docs/learning-modules.md)
        ## Guides: Future Work
        - [Learning Modules](https://docs.thousandbrains.org/docs/learning-modules.md)
        """
      })

      assert {:ok, %{pages: [%{slug: "learning-modules", area: "how-monty-works"}]}} =
               Docs.index()
    end

    test "says the site did not answer, rather than raising" do
      FakeDocsHttp.serve(%{@index => {503, "unavailable"}})

      assert {:error, :unreachable} = Docs.index()
    end
  end

  describe "the map" do
    test "is the site's own index, word for word" do
      assert {:ok, text} = Docs.map()

      assert text == @index_text
    end

    test "keeps one area's block whole, heading and all" do
      assert {:ok, block} = Docs.map("how-to-use-monty")

      # The block is the site's own lines, so it keeps the newline the next
      # section's heading follows.
      assert block ==
               "## Guides: How to Use Monty\n" <>
                 "- [Getting Started](https://docs.thousandbrains.org/docs/getting-started.md): " <>
                 "How to get the code running.\n"
    end

    test "names the areas when the one asked for does not exist" do
      assert {:error, {:unknown_area, "community", areas}} = Docs.map("community")

      assert "how-monty-works" in areas
      assert "future-work" not in areas
    end

    test "says the site did not answer, rather than raising" do
      FakeDocsHttp.serve(%{@index => {:error, :timeout}})

      assert {:error, :unreachable} = Docs.map()
    end
  end

  test "the address a page is published at is derived from its slug, so nothing has to know it" do
    assert Docs.online("learning-modules") == @site <> "/docs/learning-modules"
  end
end
