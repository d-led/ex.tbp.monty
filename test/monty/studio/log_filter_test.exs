defmodule Monty.Studio.LogFilterTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.LogFilter

  defp lines(texts), do: Enum.map(texts, &%{text: &1})

  describe "the words a filter is asking for" do
    test "a blank filter asks for nothing" do
      assert LogFilter.tokens("") == []
      assert LogFilter.tokens("   ") == []
      assert LogFilter.tokens(nil) == []
    end

    test "words are split on any whitespace and compared in lower case" do
      assert LogFilter.tokens("  Votes\tDEADLINE  ") == ["votes", "deadline"]
    end
  end

  describe "which lines a filter keeps" do
    test "every word must appear, in any order, anywhere in the line" do
      tokens = LogFilter.tokens("votes deadline")

      assert LogFilter.matches?(tokens, "step 3 · votes 2/2 · deadline hit")
      assert LogFilter.matches?(tokens, "deadline: votes arrived late")

      # One word is not enough, and neither is the other one.
      refute LogFilter.matches?(tokens, "step 3 · votes 2/2")
      refute LogFilter.matches?(tokens, "step 4 · deadline hit")
    end

    test "words match inside longer words, so less typing is needed" do
      assert LogFilter.matches?(LogFilter.tokens("percept"), "percepts patch,view_finder")
    end

    test "a blank filter keeps every line" do
      everything = lines(["one", "two"])

      assert LogFilter.apply(everything, "") == everything
      assert LogFilter.apply(everything, nil) == everything
    end

    test "a filter keeps the matching lines in the order they arrived" do
      log = lines(["step 0 · votes 1/1", "step 1 · goals 0", "step 2 · votes 0/0"])

      assert LogFilter.apply(log, "votes") |> Enum.map(& &1.text) == [
               "step 0 · votes 1/1",
               "step 2 · votes 0/0"
             ]
    end

    test "a line without text is still a line" do
      assert LogFilter.apply([%{level: :error}], "error") |> length() == 1
    end
  end
end
