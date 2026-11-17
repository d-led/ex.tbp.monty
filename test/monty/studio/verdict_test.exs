defmodule Monty.Studio.VerdictTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Verdict

  # A module's belief as the record keeps it: its terminal state, the object it
  # named, and the hypothesis space behind it.
  defp matched(object), do: belief("match", object)

  defp timed_out(object) do
    %{
      "terminal_state" => "time_out",
      "mlh" => %{"graph_id" => object},
      "graphs" => %{object => %{"max_evidence" => 3.0}}
    }
  end

  defp refused, do: belief("no_match", nil)

  defp undecided(object), do: belief(nil, nil) |> Map.put("mlh", %{"graph_id" => object})

  defp belief(state, object) do
    %{
      "terminal_state" => state,
      "detected_object" => object,
      "graphs" => if(object, do: %{object => %{"max_evidence" => 5.0}}, else: %{})
    }
  end

  describe "what the modules concluded" do
    test "names the object the modules that concluded agreed on" do
      verdict =
        Verdict.of(%{
          "learning_module_0" => matched("mug"),
          "learning_module_1" => matched("mug")
        })

      assert verdict.object == "mug"
      assert verdict.agreed?
      assert verdict.undecided == []
    end

    # Monty ends the episode on the first match and times the rest out, so a run
    # of five modules is one `match` and four `time_out`. The four are not
    # dissent: they held their belief when the episode ended.
    test "a module that ran out of steps is named as still believing, not as dissent" do
      verdict =
        Verdict.of(%{
          "learning_module_0" => matched("mug"),
          "learning_module_1" => timed_out("mug"),
          "learning_module_2" => timed_out("bowl")
        })

      assert verdict.agreed?
      assert verdict.dissent == []

      assert verdict.undecided |> Enum.map(&{&1.module_id, &1.object}) ==
               [{"learning_module_1", "mug"}, {"learning_module_2", "bowl"}]
    end

    test "two objects named by two concluded modules is no agreement" do
      verdict =
        Verdict.of(%{
          "learning_module_0" => matched("mug"),
          "learning_module_1" => matched("bowl")
        })

      refute verdict.agreed?
      assert verdict.object == nil
      assert verdict.concluded |> Enum.map(& &1.object) |> Enum.sort() == ["bowl", "mug"]
    end

    # A step in the middle of an episode has concluded nothing, which is not a
    # disagreement either.
    test "a step where nothing has concluded names no object" do
      verdict = Verdict.of(%{"learning_module_0" => undecided("mug")})

      refute verdict.agreed?
      assert verdict.object == nil
      assert verdict.concluded == []
      assert [%{module_id: "learning_module_0", object: "mug"}] = verdict.undecided
    end

    test "a module that refused the object neither agrees nor dissents" do
      verdict =
        Verdict.of(%{
          "learning_module_0" => matched("mug"),
          "learning_module_1" => refused()
        })

      assert verdict.agreed?
      assert verdict.object == "mug"
      assert [%{module_id: "learning_module_1", object: nil}] = verdict.dissent
    end

    test "a step that reported no beliefs has no verdict" do
      assert Verdict.of(%{}) == nil
    end

    # A module that was timed out before it built a hypothesis still has its
    # graphs, and its strongest is what it believed.
    test "a module with no current hypothesis is read from its strongest graph" do
      belief = %{"terminal_state" => "time_out", "graphs" => %{"mug" => %{"max_evidence" => 2.0}}}

      assert [%{object: "mug"}] = Verdict.of(%{"learning_module_0" => belief}).undecided
    end
  end
end
