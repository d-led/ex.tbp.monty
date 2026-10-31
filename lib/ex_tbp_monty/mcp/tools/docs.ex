defmodule ExTbpMonty.Mcp.Tools.Docs do
  @moduledoc """
  Reading Monty's published documentation: search, one page, and the index.

  These are the tools that answer "what does the project say" — about the
  theory, about how Monty works, about how to use it. Every answer carries the
  page it came from and the address it is published at, so a claim can be
  checked instead of believed.

  The wording of a failure is part of the tool: a model that is told *the site
  could not be reached* retries, and one that is handed an exception retries
  nothing. So every error below says what happened and what to do instead.
  """

  alias ExTbpMonty.Mcp.{Args, Docs}

  @unreachable "Monty's documentation site could not be reached just now. " <>
                 "Try again in a moment — every documentation tool reads the same site."

  @doc "`monty_search_docs`: the passages the site's search finds for a question."
  def search(args, _ctx) do
    with {:ok, query} <- Args.required(args, "query"),
         {:ok, area} <- Args.optional(args, "area"),
         {:ok, limit} <- Args.integer(args, "limit", default: 6, min: 1, max: 20) do
      case Docs.search(query, limit: limit, area: area) do
        {:ok, []} ->
          {:ok, %{text: nothing_found(query), structured: %{query: query, hits: []}}}

        {:ok, hits} ->
          {:ok, %{text: hits_text(hits), structured: %{query: query, hits: hits}}}

        {:error, reason} ->
          {:error, search_error(reason)}
      end
    end
  end

  @doc "`monty_read_doc`: one page, whole."
  def read(args, _ctx) do
    with {:ok, slug} <- Args.required(args, "slug") do
      case Docs.read(slug) do
        {:ok, page} ->
          {:ok,
           %{
             text: page_text(page),
             structured: %{
               slug: page.slug,
               title: page.title,
               online: page.online,
               sections: page.sections,
               markdown: page.markdown
             }
           }}

        {:error, reason} ->
          {:error, read_error(slug, reason)}
      end
    end
  end

  @doc "`monty_docs_index`: what documentation there is."
  def index(args, _ctx) do
    with {:ok, area} <- Args.optional(args, "area") do
      case Docs.index() do
        {:ok, %{areas: areas, pages: pages}} ->
          area_index(areas, pages, area)

        {:error, _reason} ->
          {:error, @unreachable}
      end
    end
  end

  defp area_index(areas, pages, nil),
    do: {:ok, %{text: index_text(areas, pages), structured: %{areas: areas, pages: pages}}}

  defp area_index(areas, pages, area) do
    case Enum.filter(pages, &(&1.area == area)) do
      [] ->
        {:error, "There is no `#{area}` area. Areas: #{Enum.map_join(areas, ", ", & &1.name)}."}

      pages ->
        {:ok, %{text: index_text(areas, pages), structured: %{areas: areas, pages: pages}}}
    end
  end

  @doc "`monty_docs_map`: the site's own machine index, verbatim."
  def map(args, _ctx) do
    with {:ok, area} <- Args.optional(args, "area") do
      case Docs.map(area) do
        {:ok, text} ->
          {:ok, %{text: text, structured: %{area: area, pages: Enum.count(listed_lines(text))}}}

        {:error, reason} ->
          {:error, search_error(reason)}
      end
    end
  end

  # The map's own lines, in the site's format: one bullet per page.
  defp listed_lines(text) do
    text |> String.split("\n") |> Enum.filter(&Regex.match?(~r/\A\s*- \[/u, &1))
  end

  defp nothing_found(query) do
    "Monty's docs have no page matching `#{query}`. " <>
      "Try the words the project uses (`learning module`, `voting`, `heterarchy`, `CMP`), " <>
      "or monty_docs_index to see what there is."
  end

  defp search_error({:unknown_area, area, areas}) do
    "There is no `#{area}` area. Areas: #{Enum.map_join(areas, ", ", & &1)}."
  end

  defp search_error(_unreachable), do: @unreachable

  defp read_error(slug, :invalid_slug) do
    "`#{slug}` is not a page slug. A slug is the last part of a published address — " <>
      "`learning-modules` for https://docs.thousandbrains.org/docs/learning-modules — " <>
      "and monty_docs_index lists them."
  end

  defp read_error(slug, :not_found) do
    "There is no page `#{slug}`. See monty_docs_index for the ones there are."
  end

  defp read_error(_slug, _unreachable), do: @unreachable

  defp hits_text(hits) do
    hits
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {hit, index} ->
      "**#{index}. #{hit.title}**\n#{hit.online}\n`#{hit.slug}`\n\n" <> hit.excerpt
    end)
  end

  defp page_text(page) do
    "# #{page.title}\n#{page.online}\n`#{page.slug}`\n\n" <> page.markdown
  end

  defp index_text(areas, pages) do
    totals = Enum.map_join(areas, ", ", &"#{&1.name} (#{&1.pages})")

    grouped =
      pages
      |> Enum.group_by(& &1.area)
      |> Enum.sort_by(fn {area, _pages} -> area end)
      |> Enum.map_join("\n\n", fn {area, pages} ->
        "## #{area}\n" <>
          Enum.map_join(pages, "\n", fn page -> "- `#{page.slug}` — #{page.title}" end)
      end)

    "Areas: #{totals}\n\n" <> grouped
  end
end
