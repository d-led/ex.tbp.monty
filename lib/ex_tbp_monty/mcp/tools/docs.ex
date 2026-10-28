defmodule ExTbpMonty.Mcp.Tools.Docs do
  @moduledoc """
  Reading Monty's documentation: search, one page, and the index.

  These are the tools that answer "what does the project say" — about the
  theory, about how Monty works, about how to use it. Every answer carries the
  page it came from and the address it is published at, so a claim can be
  checked instead of believed.
  """

  alias ExTbpMonty.Mcp.{Args, Docs}

  @doc "`monty_search_docs`: the passages that answer a question."
  def search(args, _ctx) do
    with {:ok, query} <- Args.required(args, "query"),
         {:ok, area} <- Args.optional(args, "area"),
         {:ok, limit} <- Args.integer(args, "limit", default: 6, min: 1, max: 20) do
      case Docs.search(query, limit: limit, area: area) do
        {:ok, []} ->
          {:ok,
           %{
             text:
               "No passage of Monty's docs has all of `#{query}` in it. " <>
                 "Try fewer words, or monty_docs_index to see what is there.",
             structured: %{query: query, hits: []}
           }}

        {:ok, hits} ->
          {:ok, %{text: hits_text(hits), structured: %{query: query, hits: hits}}}

        {:error, :empty_query} ->
          {:error, "`query` needs a word that is not a stop word."}
      end
    end
  end

  @doc "`monty_read_doc`: one page, whole."
  def read(args, _ctx) do
    with {:ok, path} <- Args.required(args, "path") do
      case Docs.read(path) do
        {:ok, page} ->
          {:ok,
           %{
             text: page_text(page),
             structured: %{
               path: page.path,
               title: page.title,
               area: page.area,
               online: page.online,
               sections: page.sections,
               markdown: page.markdown
             }
           }}

        {:error, :invalid_path} ->
          {:error,
           "`#{path}` is not a page path. Give a path from monty_docs_index, " <>
             "such as `theory/theory-overview.md`."}

        {:error, :not_found} ->
          {:error, "There is no page `#{path}`. See monty_docs_index."}
      end
    end
  end

  @doc "`monty_docs_index`: what documentation there is."
  def index(args, _ctx) do
    with {:ok, area} <- Args.optional(args, "area") do
      areas = Docs.areas()
      pages = Docs.pages() |> Enum.filter(&(is_nil(area) or &1.area == area))

      case pages do
        [] ->
          {:error, "There is no `#{area}` area. Areas: #{Enum.map_join(areas, ", ", & &1.name)}."}

        pages ->
          {:ok, %{text: index_text(areas, pages), structured: %{areas: areas, pages: pages}}}
      end
    end
  end

  defp hits_text(hits) do
    hits
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {hit, index} ->
      "**#{index}. #{hit.title} — #{hit.heading}**\n" <>
        "#{hit.online}\n" <>
        "`#{hit.path}`\n\n" <> hit.excerpt
    end)
  end

  defp page_text(page) do
    "# #{page.title}\n" <>
      "#{page.online}\n`#{page.path}`\n\n" <> page.markdown
  end

  defp index_text(areas, pages) do
    totals = Enum.map_join(areas, ", ", &"#{&1.name} (#{&1.pages})")

    grouped =
      pages
      |> Enum.group_by(& &1.area)
      |> Enum.sort_by(fn {area, _pages} -> area end)
      |> Enum.map_join("\n\n", fn {area, pages} ->
        "## #{area}\n" <>
          Enum.map_join(pages, "\n", fn page -> "- `#{page.path}` — #{page.title}" end)
      end)

    "Areas: #{totals}\n\n" <> grouped
  end
end
