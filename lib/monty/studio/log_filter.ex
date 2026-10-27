defmodule Monty.Studio.LogFilter do
  @moduledoc """
  Which log lines match what a person typed into the filter box.

  Every non-empty word must appear in a line for the line to be shown, and the
  words do not have to be adjacent or in order: `votes deadline` finds the line
  that mentions both, wherever they are. Words are matched case-insensitively
  and as substrings, so `percept` finds `percepts` — a filter that insists on
  whole words makes a reader type more than they know.

  A blank filter matches everything, which is the state a page starts in.
  """

  @type line :: %{optional(:text) => String.t(), optional(String.t()) => term()}

  @doc "The words a filter text is asking for."
  @spec tokens(String.t() | nil) :: [String.t()]
  def tokens(nil), do: []

  def tokens(text) do
    text
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  @doc "Whether a line contains every word of the filter."
  @spec matches?([String.t()], String.t()) :: boolean()
  def matches?(tokens, text) do
    text = String.downcase(text)
    Enum.all?(tokens, &String.contains?(text, &1))
  end

  @doc """
  The lines a filter keeps, in the order they arrived.

  The whole log is filtered, not the lines that arrived after the filter was
  typed: a reader who narrows the log is asking about the run, not about the
  last second of it.
  """
  @spec apply([map()], String.t() | nil) :: [map()]
  def apply(lines, filter) do
    case tokens(filter) do
      [] -> lines
      wanted -> Enum.filter(lines, &matches?(wanted, text_of(&1)))
    end
  end

  @doc "The text a line is filtered on: its `:text`, or the line itself."
  @spec text_of(map()) :: String.t()
  def text_of(%{text: text}), do: text
  def text_of(line) when is_binary(line), do: line
  def text_of(line), do: inspect(line)
end
