defmodule ExTbpMonty.Mcp.Docs do
  @moduledoc """
  Monty's documentation, as the project publishes it.

  Every answer here comes from `docs.thousandbrains.org` — the site the project
  builds from its own checkout — so the text a client is given is the text a
  reader of the published docs gets, and the address it is given is one a claim
  can be checked at. Nothing is read from a checkout beside this application
  (that is a *maintenance* thing: `mix monty.inputs` copies configs from one),
  and nothing is cached, because a stale answer about documentation is worse
  than a slow one.

  Three of the site's own endpoints do the work:

    * `…/api-next/v2/search` — the site's search, which is what a reader uses
      too, so a term the site knows is found and a term it does not is not
    * `/docs/<slug>.md` — a page as markdown, which is what `monty_read_doc`
      hands back whole
    * `/llms.txt` — every page, under the area it belongs to, which is the
      index `monty_docs_index` lists

  A page is named by its **slug** — `learning-modules`, not
  `how-monty-works/learning-modules.md` — because that is how the site
  addresses it. The slug is also the last segment of the published URL, which
  is why `online/1` can be derived from it rather than looked up.
  """

  require Logger

  alias ExTbpMonty.Mcp.{Docs.Http, Markdown}

  @default_site "https://docs.thousandbrains.org"

  @type page :: %{
          slug: String.t(),
          title: String.t(),
          area: String.t() | nil,
          description: String.t(),
          online: String.t()
        }

  @type hit :: %{
          slug: String.t(),
          title: String.t(),
          excerpt: String.t(),
          section: String.t() | nil,
          breadcrumbs: [String.t()],
          online: String.t()
        }

  @type area :: %{name: String.t(), pages: pos_integer()}

  @doc """
  The documentation site.

  `:docs_site` replaces it, which is how a test points every tool at one stub.
  """
  @spec site() :: String.t()
  def site, do: Application.get_env(:ex_tbp_monty, :docs_site, @default_site)

  @doc """
  The documentation version to answer from, or `nil` for the current one.

  The site serves the newest release at the bare `/docs/` path and keeps older
  ones under their version (`/v0.56/docs/…`); the search endpoint takes a
  `version` and defaults the same way. `:docs_version` pins a deployment to the
  release its port is chasing, e.g. `"0.56"`.
  """
  @spec version() :: String.t() | nil
  def version, do: Application.get_env(:ex_tbp_monty, :docs_version)

  @doc "The address a page is published at."
  @spec online(String.t()) :: String.t()
  def online(slug), do: site() <> "/docs/" <> slug

  # -- searching -------------------------------------------------------------

  @doc """
  The pages the site's own search finds for `query`.

  One request to the site's search endpoint; `:limit` is what it asks for and
  `:area` narrows the answer to one area of the index (a second request, only
  when asked for). An area that does not exist is an error naming the ones that
  do, because a caller who typed one wants to see the list.

  A site that cannot be reached is `{:error, :unreachable}` — the caller says so
  in words. Nothing here raises: a tool that cannot answer still has to answer.
  """
  @spec search(String.t(), keyword()) :: {:ok, [hit()]} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    with {:ok, body} <- json(search_url(query, limit)),
         {:ok, hits} <- hits(body) do
      narrow(hits, Keyword.get(opts, :area))
    end
  end

  # A result without a slug is not a page this module can name, so it is dropped
  # rather than turned into an address built from `nil`.
  defp hits(%{"data" => data}) when is_list(data) do
    {:ok, data |> Enum.filter(&slugged?/1) |> Enum.map(&hit/1)}
  end

  defp hits(_not_an_answer), do: {:error, :unreachable}

  defp slugged?(result) when is_map(result),
    do: is_binary(result["slug"]) and result["slug"] != ""

  defp slugged?(_not_a_page), do: false

  defp hit(result) do
    %{
      slug: result["slug"],
      title: result["title"] || humanise(result["slug"]),
      excerpt: excerpt(result["highlights"]),
      section: result["section"],
      breadcrumbs: result["breadcrumbs"] || [],
      online: get_in(result, ["url", "full"]) || online(result["slug"])
    }
  end

  # The site answers with the matched words in context, split into "hit" and
  # "text" pieces. Joined back together they read as the sentence the search
  # selected, which is what a reader wants to see.
  defp excerpt(highlights) when is_list(highlights) do
    highlights
    |> Enum.map_join(fn
      %{"value" => value} when is_binary(value) -> value
      _other -> ""
    end)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp excerpt(_none), do: ""

  defp narrow(hits, nil), do: {:ok, hits}

  defp narrow(hits, area) do
    with {:ok, %{areas: areas, pages: pages}} <- index() do
      case Enum.find(areas, &(&1.name == area)) do
        nil ->
          {:error, {:unknown_area, area, Enum.map(areas, & &1.name)}}

        %{name: area} ->
          in_area = MapSet.new(pages, fn page -> {page.slug, page.area} end)

          {:ok,
           hits
           |> Enum.filter(&MapSet.member?(in_area, {&1.slug, area}))
           |> Enum.map(&Map.put(&1, :area, area))}
      end
    end
  end

  # -- reading ---------------------------------------------------------------

  @doc """
  One page, whole, in markdown.

  The page's front matter is dropped (on the site it carries only `updatedAt`
  and a pointer to the page index), and its headings come back separately so a
  long page can be skimmed before it is read.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, :invalid_slug | :not_found | :unreachable}
  def read(slug) do
    with {:ok, slug} <- slug_of(slug) do
      case get(page_url(slug)) do
        {:ok, text} -> {:ok, content(slug, text)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp content(slug, text) do
    {_meta, body} = Markdown.frontmatter(text)

    %{
      slug: slug,
      title: Markdown.first_heading(body) || humanise(slug),
      area: nil,
      description: "",
      online: online(slug),
      markdown: body,
      sections: Markdown.headings(body)
    }
  end

  # A slug is the site's own handle on a page: lower case, words joined by
  # hyphens. Anything else — a path, a traversal, a file this module did not
  # hand out — is refused before a request is made.
  defp slug_of(slug) when is_binary(slug) do
    case slug |> String.trim() |> String.trim_trailing(".md") do
      "" -> {:error, :invalid_slug}
      cleaned -> if valid_slug?(cleaned), do: {:ok, cleaned}, else: {:error, :invalid_slug}
    end
  end

  defp slug_of(_not_a_slug), do: {:error, :invalid_slug}

  defp valid_slug?(slug), do: Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, slug)

  defp humanise(slug), do: slug |> to_string() |> String.replace("-", " ")

  # -- the index -------------------------------------------------------------

  @doc """
  Every page the site lists, and the areas they are grouped into.

  `llms.txt` is the site's own machine index — every page, under the guide area
  it belongs to — which is why it is read rather than crawled. A page listed
  under two headings is one page, so the first area wins.
  """
  @spec index() :: {:ok, %{areas: [area()], pages: [page()]}} | {:error, term()}
  def index do
    with {:ok, text} <- get(index_url()) do
      pages = text |> listed() |> Enum.uniq_by(& &1.slug)
      {:ok, %{areas: areas(pages), pages: pages}}
    end
  end

  defp areas(pages) do
    pages
    |> Enum.frequencies_by(& &1.area)
    |> Enum.map(fn {name, count} -> %{name: name, pages: count} end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The site's own machine index, verbatim.

  `llms.txt` is what the project publishes *for* a model to read: every page,
  under the area it belongs to, in the order the site lists them, each with the
  one-line description the project gives it. `index/0` answers the same question
  as a list to choose from; this hands back the project's own words, which is
  what a caller wants when the point is the map rather than a slug.

  `:area` narrows it to one block, heading included, so the answer still says
  which area it is.
  """
  @spec map(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def map(area \\ nil)

  def map(nil), do: get(index_url())

  def map(area) do
    with {:ok, text} <- get(index_url()) do
      blocks = blocks(text)

      case Enum.find(blocks, &(&1.area == area)) do
        nil -> {:error, {:unknown_area, area, Enum.map(blocks, & &1.area)}}
        block -> {:ok, block.lines}
      end
    end
  end

  # The index split at its section headings. Whatever comes before the first one
  # is the page's title and its introduction: a block belongs to an area, and
  # that text belongs to none.
  defp blocks(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, blocks ->
      cond do
        Regex.match?(~r/\A##+\s/, line) ->
          [%{area: area_of_heading(line), lines: [line]} | blocks]

        blocks == [] ->
          blocks

        true ->
          [%{hd(blocks) | lines: [line | hd(blocks).lines]} | tl(blocks)]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn block ->
      %{block | lines: block.lines |> Enum.reverse() |> Enum.join("\n")}
    end)
  end

  defp listed(text) do
    for block <- blocks(text),
        line <- String.split(block.lines, "\n"),
        page = entry(line, block.area),
        page,
        do: page
  end

  @entry ~r/\A\s*- \[(?<title>[^\]]+)\]\((?<url>[^)\s]+)\)(?::\s*(?<description>.*))?\s*\z/u

  defp entry(line, area) do
    with %{"title" => title, "url" => url} = match <- Regex.named_captures(@entry, line),
         slug when is_binary(slug) <- slug_in(url) do
      %{
        slug: slug,
        title: title,
        area: area,
        description: Map.get(match, "description") || "",
        online: online(slug)
      }
    else
      _not_an_entry -> nil
    end
  end

  # A link with no path at all is not a page (`mailto:` and friends); one that
  # has a path is addressed by its last segment, which is the page's slug.
  defp slug_in(url) do
    path = URI.parse(url).path || ""

    case path |> Path.basename() |> String.trim_trailing(".md") do
      "" -> nil
      slug -> slug
    end
  end

  defp area_of_heading(heading) do
    heading
    |> String.trim_leading("#")
    |> String.trim()
    |> String.replace_prefix("Guides: ", "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  # -- requests --------------------------------------------------------------

  defp search_url(query, limit) do
    params = [{"query", query}, {"per_page", Integer.to_string(limit)}] ++ version_param()

    site() <> "/thousandbrainsproject/api-next/v2/search?" <> URI.encode_query(params)
  end

  defp version_param do
    case version() do
      nil -> []
      version -> [{"version", version}]
    end
  end

  defp page_url(slug), do: site() <> "/docs/" <> slug <> ".md"

  defp index_url, do: site() <> "/llms.txt"

  defp json(url) do
    with {:ok, body} <- get(url) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _not_json} -> {:error, :unreachable}
      end
    end
  end

  defp get(url) do
    case http().get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> failed(url, {:http_status, status})
      {:error, reason} -> failed(url, reason)
    end
  end

  # The detail belongs in the log, not in a reader's answer: the tool says it
  # could not reach the docs, and an operator can find out why here.
  defp failed(url, reason) do
    Logger.warning("documentation request failed: #{url} (#{inspect(reason)})")
    {:error, :unreachable}
  end

  defp http, do: Application.get_env(:ex_tbp_monty, :docs_http, Http.Req)
end
