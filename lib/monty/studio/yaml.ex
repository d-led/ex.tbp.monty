defmodule Monty.Studio.Yaml do
  @moduledoc """
  A config as YAML — the format Monty's own files are written in.

  A run's snapshot is what a person opens to see what Monty was asked to do, and
  Monty answers in YAML: the same keys, the same nesting, without the braces and
  quotes that make a deep config read as one long line. What is printed parses
  back to the value it was given — the tests hold it to that, because a display
  format that loses or alters a key is a display that lies about the run.

  Values are printed plain where a YAML reader would take them as the words they
  are, and quoted where it would not: `"on"`, `"42"` and `"a: b"` are quoted,
  `mug` is not. That judgement is the only one this module makes.
  """

  @reserved ~w(true false yes no on off null ~)

  # A plain scalar may not begin with one of these: each starts something in
  # YAML's own syntax rather than a word.
  @openers [
    "-",
    "?",
    ":",
    ",",
    "[",
    "]",
    "{",
    "}",
    "#",
    "&",
    "*",
    "!",
    "|",
    ">",
    "'",
    "\"",
    "%",
    "@",
    "`"
  ]

  @typedoc """
  One line: the indent it sits at (a list item's includes its dash), the key on
  it if it has one, and what follows the key.
  """
  @type line :: {String.t(), String.t() | nil, String.t()}

  @doc "The value as YAML text."
  @spec render(term()) :: String.t()
  def render(value) do
    value
    |> block(0)
    |> Enum.map_join("\n", fn {prefix, key, rest} -> prefix <> (key || "") <> rest end)
  end

  @doc """
  The value as YAML, with each key in a span of its own.

  Keys are what a reader scans for and YAML carries no colour of its own. Every
  character printed around them is escaped where it is printed: the config is
  Monty's data and this module only ever shows it.
  """
  @spec highlight(term()) :: {:safe, iodata()}
  def highlight(value) do
    value
    |> block(0)
    |> Enum.map_join("\n", &colour/1)
    |> then(&{:safe, &1})
  end

  defp colour({prefix, nil, rest}), do: [escape(prefix), escape(rest)]

  defp colour({prefix, key, rest}),
    do: [escape(prefix), ~s(<span class="text-info">), escape(key), "</span>", escape(rest)]

  defp escape(text), do: Plug.HTML.html_escape_to_iodata(text)

  # The body of a value at `indent`: a map's keys, a list's items, or — at the
  # root of a config that is neither — the scalar itself.
  defp block(map, indent) when is_map(map) and map_size(map) == 0, do: [{pad(indent), nil, "{}"}]

  defp block(map, indent) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} -> pair(pad(indent), to_string(key), value, indent) end)
  end

  defp block([], indent), do: [{pad(indent), nil, "[]"}]
  defp block(list, indent) when is_list(list), do: Enum.flat_map(list, &item(&1, indent))

  defp block(other, indent), do: [{pad(indent), nil, scalar(other)}]

  # A pair whose value has a body — a map or a list — puts the body on the lines
  # after it, one level in; anything else fits on the key's own line.
  defp pair(prefix, key, value, indent) when is_map(value) and map_size(value) > 0,
    do: [{prefix, key, ":"} | block(value, indent + 2)]

  defp pair(prefix, key, value, indent) when is_list(value) and value != [],
    do: [{prefix, key, ":"} | block(value, indent + 2)]

  defp pair(prefix, key, value, _indent), do: [{prefix, key, ": " <> inline(value)}]

  defp inline(value) when is_map(value), do: "{}"
  defp inline(value) when is_list(value), do: "[]"
  defp inline(value), do: scalar(value)

  # A list item: a scalar after the dash, or a map whose first key shares the
  # dash's line and whose other keys line up under it.
  defp item(map, indent) when is_map(map) and map_size(map) > 0 do
    [{first_key, first_value} | rest] =
      map |> Enum.sort_by(fn {key, _value} -> to_string(key) end) |> Enum.map(&elem_pair/1)

    pair(pad(indent) <> "- ", first_key, first_value, indent + 2) ++
      Enum.flat_map(rest, fn {key, value} -> pair(pad(indent + 2), key, value, indent + 2) end)
  end

  defp item(other, indent), do: [{pad(indent), nil, "- " <> inline(other)}]

  defp elem_pair({key, value}), do: {to_string(key), value}

  defp pad(indent), do: String.duplicate(" ", indent)

  defp scalar(nil), do: "null"
  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(value) when is_number(value), do: to_string(value)

  defp scalar(value) when is_binary(value) do
    if plain?(value), do: value, else: inspect(value)
  end

  defp scalar(value), do: value |> to_string() |> scalar()

  # Whether a YAML reader would take this text back as the same plain string:
  # no syntax it would read as structure, and no word it would read as a type.
  defp plain?(text) do
    text != "" and
      text == String.trim(text) and
      String.downcase(text) not in @reserved and
      not numeric?(text) and
      not String.starts_with?(text, @openers) and
      not String.contains?(text, ["\n", ": ", " #", "${"])
  end

  defp numeric?(text) do
    match?({_number, ""}, Float.parse(text))
  end
end
