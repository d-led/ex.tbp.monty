defmodule ExTbpMonty.Mcp.Docs do
  @moduledoc """
  Monty's documentation, read as a corpus an agent can search.

  The pages are Monty's own, under the checkout that
  `Monty.Config.Source.root/0` already names for configs. The text an MCP client
  is given is therefore the text that shipped with the code it is being asked
  about — there is no second copy here to drift from the first.

  A page is split into sections at its headings, and each section is ranked on
  its own: the unit an answer cites is "this paragraph of this page", not "this
  800-line page contains the word somewhere". The ranker is deliberately small —
  term coverage, a weight on the heading, and a density correction for length —
  and says so, because a reader's index is not a search engine and should not
  pretend to be one.

  Nothing is cached. Two hundred small files are a few milliseconds to read, and
  a stale answer about documentation is worse than a slow one.
  """

  @default_base_url "https://docs.thousandbrains.org/docs/"

  alias ExTbpMonty.Mcp.Markdown

  # Words that carry no signal in a question about an architecture. Deliberately
  # short: a ranker that drops too much is a ranker that misses.
  @stopwords ~w(
    a about after all also an and any are as at be because been but by can could
    do does for from had has have how i if in into is it its just like may might
    more most much my no not of on one only or other our out over same should so
    some such than that the their them then there these they this those to too
    up us very was we were what when where which who why will with would you your
  )

  @type page :: %{
          path: String.t(),
          title: String.t(),
          area: String.t(),
          online: String.t()
        }

  @type hit :: %{
          path: String.t(),
          title: String.t(),
          heading: String.t(),
          excerpt: String.t(),
          score: float(),
          online: String.t()
        }

  @type content ::
          page()
          | %{
              markdown: String.t(),
              sections: [String.t()]
            }

  @doc """
  The directory the documentation is read from.

  `:monty_docs_dir` overrides it, which is how a test pins the corpus instead of
  asserting against whatever version of the docs happens to be checked out.
  """
  @spec root() :: Path.t()
  def root do
    Application.get_env(:ex_tbp_monty, :monty_docs_dir) ||
      Path.join(Monty.Config.Source.root(), "docs")
  end

  @doc """
  The address the pages are published at.

  Monty publishes its docs with Myst, which addresses a page by its file name
  rather than by its path in the repository, and no two pages share a name — so
  the mapping is unambiguous. It is still derived rather than known: a page the
  site has not published will read as a link that does not exist yet.
  """
  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:ex_tbp_monty, :monty_docs_url, @default_base_url)

  @doc """
  Every page, with the title it declares and the address it is published at.
  """
  @spec pages() :: [page()]
  def pages do
    page_paths()
    |> Enum.flat_map(fn path ->
      case read(path) do
        {:ok, %{path: path, title: title, area: area, online: online}} ->
          [%{path: path, title: title, area: area, online: online}]

        {:error, _reason} ->
          []
      end
    end)
  end

  @doc "The areas of the documentation, and how many pages each holds."
  @spec areas() :: [%{name: String.t(), pages: pos_integer()}]
  def areas do
    page_paths()
    |> Enum.frequencies_by(&area_of/1)
    |> Enum.map(fn {name, pages} -> %{name: name, pages: pages} end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  One page: its text, and the headings a reader can jump to.
  """
  @spec read(String.t()) :: {:ok, content()} | {:error, :invalid_path | :not_found}
  def read(path) do
    with {:ok, relative} <- inside_root(path) do
      case File.read(absolute(relative)) do
        {:ok, text} -> {:ok, content(relative, text)}
        {:error, _reason} -> {:error, :not_found}
      end
    end
  end

  defp content(relative, text) do
    {meta, body} = Markdown.frontmatter(text)

    %{
      path: relative,
      title: title_of(meta, body, relative),
      area: area_of(relative),
      online: online(relative),
      markdown: body,
      sections: Markdown.headings(body)
    }
  end

  @doc """
  Passages of the documentation that answer a question.

  Every term of the query must appear somewhere in a section for it to be
  returned; a section that merely matches a word of a longer question is noise
  a reader then has to read past. Common words are dropped first, so a question
  phrased as a sentence still searches on its content, and a plain plural finds
  the singular it is built from.
  """
  @spec search(String.t(), keyword()) :: {:ok, [hit()]} | {:error, :empty_query}
  def search(query, opts \\ []) do
    with {:ok, terms} <- terms(query) do
      limit = Keyword.get(opts, :limit, 8)
      area = Keyword.get(opts, :area)

      hits =
        page_paths()
        |> only_area(area)
        |> Enum.flat_map(&sections_of/1)
        |> Enum.map(&rank(&1, terms))
        |> Enum.reject(&(&1.score == 0.0))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      {:ok, hits}
    end
  end

  # -- reading ---------------------------------------------------------------

  defp page_paths do
    Path.wildcard(Path.join(root(), "**/*.md"))
    |> Enum.map(&Path.relative_to(&1, root()))
    |> Enum.sort()
  end

  defp absolute(relative), do: Path.join(root(), relative)

  # A path is something this module hands out; anything else is a client asking
  # to read the filesystem, which is not a documentation lookup.
  defp inside_root(path) when is_binary(path) do
    cond do
      Path.type(path) != :relative -> {:error, :invalid_path}
      ".." in Path.split(path) -> {:error, :invalid_path}
      Path.extname(path) != ".md" -> {:error, :invalid_path}
      true -> {:ok, path}
    end
  end

  defp inside_root(_not_a_path), do: {:error, :invalid_path}

  defp sections_of(relative) do
    case read(relative) do
      {:ok, page} ->
        for {heading, body} <- Markdown.sections(page.markdown),
            String.trim(body) != "" do
          %{
            path: page.path,
            title: page.title,
            heading: heading || page.title,
            body: body,
            online: page.online
          }
        end

      {:error, _reason} ->
        []
    end
  end

  defp only_area(paths, nil), do: paths
  defp only_area(paths, area), do: Enum.filter(paths, &(area_of(&1) == area))

  defp area_of(relative) do
    case Path.split(relative) do
      [area, _file] -> area
      _nested_or_top_level -> "docs"
    end
  end

  # The title in the front matter is the one the site shows; the first heading is
  # the fallback for a page that declares none.
  defp title_of(meta, body, relative) do
    case meta do
      %{"title" => title} when title != "" -> title
      _no_title -> Markdown.first_heading(body) || humanise(Path.basename(relative, ".md"))
    end
  end

  defp humanise(name), do: String.replace(name, ["-", "_"], " ")

  defp online(relative), do: base_url() <> Path.basename(relative, ".md")

  # -- ranking ---------------------------------------------------------------

  defp terms(query) do
    words =
      query
      |> String.downcase()
      |> String.split(~r/[^[:alnum:]_]+/u, trim: true)
      |> Enum.reject(&(&1 in @stopwords))
      |> Enum.map(&stem/1)
      |> Enum.uniq()

    case words do
      [] -> {:error, :empty_query}
      words -> {:ok, words}
    end
  end

  # "columns" has to find "column", and "class" has to stay "class".
  defp stem(word) do
    double_s? = String.ends_with?(word, "ss")

    if String.length(word) > 4 and String.ends_with?(word, "s") and not double_s? do
      String.slice(word, 0, -1)
    else
      word
    end
  end

  defp rank(section, terms) do
    heading = String.downcase(section.heading)
    body = String.downcase(section.body)

    counts = Enum.map(terms, fn term -> {occurrences(heading, term), occurrences(body, term)} end)
    matched = Enum.count(counts, fn {in_heading, in_body} -> in_heading + in_body > 0 end)

    Map.put(section, :score, score(matched, length(terms), counts, body))
    |> Map.put(:excerpt, excerpt(section.body, terms))
    |> Map.drop([:body])
  end

  # How much of the question the section answers, plus how densely — so a
  # section that is *about* the terms beats one that mentions them in passing.
  # A section that matches only some of the words is not an answer: it is a
  # page the reader then has to read to discover that.
  defp score(matched, terms, _counts, _body) when matched < terms, do: 0.0

  defp score(matched, terms, counts, body) do
    coverage = matched / terms

    raw =
      Enum.reduce(counts, 0, fn {in_heading, in_body}, total ->
        total + 6 * in_heading + min(in_body, 12)
      end)

    coverage * 10 + raw / (1 + String.length(body) / 1_200)
  end

  defp occurrences(text, term), do: text |> String.split(term) |> length() |> Kernel.-(1)

  @excerpt_size 240

  defp excerpt(body, terms) do
    flat = body |> String.replace(~r/[ \t]+/, " ") |> String.replace(~r/\n{2,}/, "\n\n")

    case Enum.find_value(terms, &character_index(flat, &1)) do
      nil -> truncate(flat, 0)
      index -> truncate(flat, index)
    end
  end

  # Grapheme-wise, so the window never starts inside a character: the docs are
  # not ASCII-only and a slice through a codepoint would not be a string at all.
  defp character_index(text, term) do
    case :binary.match(text, term) do
      {offset, _length} -> text |> binary_part(0, offset) |> String.length()
      :nomatch -> nil
    end
  end

  defp truncate(text, index) do
    length = String.length(text)
    start = max(index - div(@excerpt_size, 3), 0)

    text
    |> String.slice(start, @excerpt_size)
    |> String.trim()
    |> then(&if start > 0, do: "…" <> &1, else: &1)
    |> then(&if length > start + @excerpt_size, do: &1 <> "…", else: &1)
  end
end
