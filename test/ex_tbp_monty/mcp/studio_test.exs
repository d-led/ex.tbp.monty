defmodule ExTbpMonty.Mcp.StudioTest do
  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Mcp
  alias ExTbpMonty.Mcp.Studio
  alias Monty.Test.Tmp

  describe "what this deployment is" do
    test "counts the experiments, and says how many runs are in each state" do
      studio = Studio.describe()

      assert studio.experiments > 100
      assert is_map(studio.runs)

      assert Enum.all?(studio.runs, fn {state, count} ->
               is_binary(state) and is_integer(count) and count >= 0
             end)
    end

    test "reports the parallelism from the queue, not from a document" do
      studio = Studio.describe()

      # A limit, when there is a queue to read it from; and a process with no
      # queue says exactly that instead of naming a number it cannot see.
      case studio.parallel.episodes_at_once do
        nil -> refute studio.parallel.live?
        limit -> assert limit >= 1 and studio.parallel.live?
      end

      # `running` is a list of ids in Oban; a caller wants the number.
      assert is_integer(studio.parallel.running_now)
      assert studio.parallel.one_part_per_run
      assert studio.parallel.how =~ ":studio"
    end

    # The number an assistant is told is the number the deployment set. It is read
    # from the queue's configuration rather than remembered, which is what makes
    # `MONTY_STUDIO_CONCURRENCY` answerable through this tool at all — and what
    # stops an answer from describing a deployment that no longer exists.
    test "says how many runs this deployment allows at once" do
      with_configured_runs(5, fn ->
        studio = Studio.describe()

        # This process runs no queue, so the number is the configured one and the
        # answer says it is not live rather than pretending to be a running limit.
        refute studio.parallel.live?
        assert studio.parallel.episodes_at_once == 5
      end)
    end

    test "says which world a run steps, and whether the interpreter is there" do
      studio = Studio.describe()

      # The suite substitutes the stand-in (`config/test.exs`), which is the only
      # reason this is not `mujoco`: a deployment cannot choose a world, and
      # MuJoCo is what a config written for MuJoCo means
      # (`docs/simulator-port.md`).
      assert studio.world.mode in ~w(mujoco synthetic habitat)
      assert is_binary(studio.world.note)
      assert Map.has_key?(studio.world, :peer_interpreter)
    end

    # The sentence a model reads is the node's answer, not a list written when
    # there were two worlds: a third world this build can step and does not name
    # is a world no caller ever asks for.
    test "the note names every world this node can step, not the ones it was written with" do
      Tmp.app_env(:world_simulator, :mujoco)

      note = Studio.describe().world.note
      others = Enum.reject(Monty.Studio.Setup.worlds(), &(&1 == :mujoco))

      assert others != []
      for world <- others, do: assert(note =~ ~s(`world: "#{world}"`))
    end

    test "says MuJoCo when nothing configured a world, which is every deployment" do
      Tmp.app_env(:world_simulator, nil)

      assert Studio.describe().world.mode == "mujoco"
    end

    test "lists the prerequisites with whether each is present" do
      for prerequisite <- Studio.describe().prerequisites do
        assert %{id: id, present?: present?, path: path} = prerequisite
        assert is_binary(id)
        assert is_boolean(present?)
        assert is_binary(path)
      end
    end

    test "says how much room is left where a run and a download write" do
      assert [run_place, download_place] = Studio.describe().storage

      assert run_place.what == "run artifacts and logs"
      assert download_place.what == "prerequisite downloads"

      for place <- Studio.describe().storage do
        assert Path.type(place.path) == :absolute

        assert %{total_bytes: total, free_bytes: free, percent: percent, mount: mount} =
                 place.device

        assert total > 0
        assert free >= 0 and free <= total
        assert percent in 0..100
        assert is_binary(mount)
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

    test "answers how much space is left in words a person reads" do
      assert {:ok, %{text: text}} = Mcp.Tools.call("monty_studio", %{}, %{base_url: "http://x"})

      assert text =~ "Storage:"
      assert text =~ ~r/run artifacts and logs at .*: \d+(\.\d+)? (B|KiB|MiB|GiB|TiB) free of/
      assert text =~ "% used"
    end
  end

  defp with_configured_runs(runs, work) do
    previous = Application.get_env(:ex_tbp_monty, Oban)
    Application.put_env(:ex_tbp_monty, Oban, Keyword.put(previous, :queues, studio: runs))
    on_exit(fn -> Application.put_env(:ex_tbp_monty, Oban, previous) end)
    work.()
  end
end
