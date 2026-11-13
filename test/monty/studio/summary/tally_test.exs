defmodule Monty.Studio.Summary.TallyTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Summary

  describe "the tally of a run's episodes" do
    test "counts what each module concluded, episode by episode" do
      tally =
        %{}
        |> Summary.tally(%{"lm_0" => :match, "lm_1" => :time_out})
        |> Summary.tally(%{"lm_0" => :match, "lm_1" => :match})
        |> Summary.tally(%{"lm_0" => :no_match})

      assert tally == %{
               "lm_0" => %{match: 2, no_match: 1},
               "lm_1" => %{match: 1, time_out: 1}
             }
    end

    test "a module that did not conclude an episode is not counted for it" do
      assert Summary.tally(%{}, %{}) == %{}
    end

    # A step budget that ran out before the module had an answer leaves a blank
    # where a conclusion would be — the record spells it `""`, a summary `nil`.
    # Counting either as a state would put a blank in the line and the episode in
    # a denominator it does not belong to.
    test "an episode a module concluded nothing about is not counted" do
      assert Summary.tally(%{}, %{"lm_0" => "", "lm_1" => nil}) == %{}

      assert Summary.tally(%{}, %{"lm_0" => "", "lm_1" => :match}) == %{
               "lm_1" => %{match: 1}
             }
    end
  end

  describe "one line of it" do
    test "says each module's matches first, then the rest, over the episode count" do
      line =
        Summary.outcomes_line(%{
          "lm_1" => %{match: 61, time_out: 5},
          "lm_0" => %{match: 66}
        })

      assert line == "lm_0: match 66 of 66 · lm_1: match 61, time_out 5 of 66"
    end

    test "a run that concluded nothing says so rather than showing an empty line" do
      assert Summary.outcomes_line(%{}) == "no episodes concluded"
    end

    test "reads the record's own spellings, where every key is a string" do
      recorded = %{"lm_0" => %{"time_out" => 3, "match" => 7}}

      assert Summary.outcomes_line(recorded) == "lm_0: match 7, time_out 3 of 10"
    end
  end
end
