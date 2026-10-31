defmodule ExTbpMonty.Mcp.StudioTest do
  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Mcp
  alias ExTbpMonty.Mcp.Studio

  describe "what this deployment is" do
    test "counts the experiments, and says how many runs are in each state" do
      studio = Studio.describe()

      assert studio.experiments > 200
      assert is_map(studio.runs)

      assert Enum.all?(studio.runs, fn {state, count} ->
               is_binary(state) and is_integer(count) and count >= 0
             end)
    end

    test "reports the parallelism from the queue, not from a document" do
      studio = Studio.describe()

      assert is_nil(studio.parallel.episodes_at_once) or
               (is_integer(studio.parallel.episodes_at_once) and
                  studio.parallel.episodes_at_once >= 1)

      # `running` is a list of ids in Oban; a caller wants the number.
      assert is_nil(studio.parallel.running_now) or is_integer(studio.parallel.running_now)
      assert studio.parallel.one_episode_per_run
      assert studio.parallel.how =~ ":studio"
    end

    test "says which world a run steps, and whether the interpreter is there" do
      studio = Studio.describe()

      assert studio.world.mode in ~w(synthetic habitat)
      assert is_binary(studio.world.note)
      assert Map.has_key?(studio.world, :peer_interpreter)
    end

    test "lists the prerequisites with whether each is present" do
      for prerequisite <- Studio.describe().prerequisites do
        assert %{id: id, present?: present?, path: path} = prerequisite
        assert is_binary(id)
        assert is_boolean(present?)
        assert is_binary(path)
      end
    end
  end

  describe "the tool an assistant calls" do
    test "answers the parallel question with a number a sentence can carry" do
      ctx = %{base_url: "http://localhost:4000"}

      assert {:ok, %{text: text, structured: structured}} =
               Mcp.Tools.call("monty_studio", %{}, ctx)

      assert text =~ "experiments preconfigured"
      assert text =~ "Parallel:"
      assert text =~ "run_parallel.py"
      assert text =~ "/runs"

      # A test process runs no queue; when there is one, its number is in the
      # sentence rather than only in the structured half.
      case structured.parallel.episodes_at_once do
        nil -> assert text =~ "no queue is running here"
        count -> assert text =~ "Parallel: #{count} episode(s) at a time"
      end
    end

    test "is listed first, as the tool for what this deployment is" do
      assert [{"The studio", [tool]} | _rest] = Mcp.Tools.families()
      assert tool["name"] == "monty_studio"
      assert tool["annotations"]["readOnlyHint"] == true
    end
  end
end
