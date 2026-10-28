defmodule ExTbpMonty.Mcp.Markdown do
  @moduledoc """
  The little of Markdown these pages need read structurally.

  Monty's documentation is written for a site generator, not for a program: it
  opens with front matter, and its headings are the units a reader navigates by.
  Both are read here, once, for the docs and the roadmap alike, so a page is
  divided into sections the same way whichever question is being answered.

  A `#` at the start of a line inside a fenced code block is a comment, not a
  heading — Monty's docs are full of Python and shell, and a splitter that does
  not know that turns an example into a table of contents.
  """

  @type section :: {String.t() | nil, String.t()}

  @doc """
  A page's front matter and its text.

  Front matter is the `---` block at the very start, if there is one. Values are
  read as text and a key without one (the roadmap's `improved-metric` is often
  blank) becomes `""`; nothing here needs YAML's types.
  """
  @spec frontmatter(String.t()) :: {map(), String.t()}
  def frontmatter(text) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n/s, text) do
      [whole, block] -> {fields(block), String.replace_prefix(text, whole, "")}
      nil -> {%{}, text}
    end
  end

  defp fields(block) do
    for line <- String.split(block, "\n"),
        [key, value] <- [String.split(line, ":", parts: 2)],
        into: %{} do
      {String.trim(key), String.trim(value)}
    end
  end

  @doc """
  The page split at its headings, in reading order.

  The first section's heading is `nil`: whatever comes before the first heading
  belongs to the page's introduction, and the caller names it after the page.
  """
  @spec sections(String.t()) :: [section()]
  def sections(markdown) do
    markdown
    |> String.split("\n")
    |> collect([], nil, false)
  end

  @doc "The headings a reader can jump to."
  @spec headings(String.t()) :: [String.t()]
  def headings(markdown) do
    for {heading, _body} <- sections(markdown), heading, do: heading
  end

  @doc "The first heading of a page, which is its title when it declares none."
  @spec first_heading(String.t()) :: String.t() | nil
  def first_heading(markdown) do
    Enum.find_value(String.split(markdown, "\n"), fn line ->
      if heading?(line), do: text_of(line)
    end)
  end

  @doc "Whether a line is a heading."
  @spec heading?(String.t()) :: boolean()
  def heading?(line), do: Regex.match?(~r/\A#+\s+\S/, line)

  @doc "A heading line without its hashes."
  @spec text_of(String.t()) :: String.t()
  def text_of(line), do: line |> String.trim_leading("#") |> String.trim()

  defp collect([], lines, heading, _in_fence),
    do: [{heading, lines |> Enum.reverse() |> Enum.join("\n")}]

  defp collect([line | rest], lines, heading, in_fence) do
    cond do
      fence?(line) ->
        collect(rest, [line | lines], heading, not in_fence)

      not in_fence and heading?(line) ->
        done = {heading, lines |> Enum.reverse() |> Enum.join("\n")}
        [done | collect(rest, [], text_of(line), false)]

      true ->
        collect(rest, [line | lines], heading, in_fence)
    end
  end

  defp fence?(line), do: line |> String.trim_leading() |> String.starts_with?(["```", "~~~"])
end
