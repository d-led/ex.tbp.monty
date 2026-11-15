defmodule Monty.Studio.EvalStatsTest do
  @moduledoc """
  A run's `eval_stats.csv` read as what the run did.

  The cases are the questions a comparison asks of a file: what each episode
  concluded, why it ended, whether the target was among the possible matches,
  what it cost, and — with two files — which episodes the two runs disagree on.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.EvalStats

  @columns "episode_seed,primary_performance,num_steps,monty_steps,time,TFNP," <>
             "num_possible_matches,rotation_error,detected_location,primary_target_position," <>
             "possible_match_sources\n"

  defp file!(rows, columns \\ @columns) do
    path = Path.join(System.tmp_dir!(), "eval_stats_#{System.unique_integer([:positive])}.csv")
    File.write!(path, columns <> Enum.join(rows, "\n") <> "\n")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp episode(seed, outcome, steps \\ 20, tfnp \\ "target_in_possible_matches_(TP)") do
    "#{seed},#{outcome},#{steps},#{steps * 7},1.5,#{tfnp},1,0.1," <>
      "[-0.01 1.46 0.04],[0.0 1.5 0.0],\"['mug', 'cup']\""
  end

  describe "one run" do
    test "says what each episode concluded" do
      run =
        EvalStats.read(
          file!([episode(1, "correct"), episode(2, "correct_mlh"), episode(3, "confused")])
        )

      assert EvalStats.outcomes(run) == %{"recognised" => 2, "confused" => 1}
    end

    test "says why each episode ended, which is the recognition policy's answer" do
      run =
        EvalStats.read(
          file!([episode(1, "correct"), episode(2, "pose_time_out"), episode(3, "no_match")])
        )

      assert EvalStats.exits(run) == %{
               "matched" => 1,
               "pose_not_converged" => 1,
               "steps_exhausted" => 1
             }
    end

    test "says whether the target was among the possible matches" do
      run =
        EvalStats.read(
          file!([
            episode(1, "correct"),
            episode(2, "confused", 20, "unknown_object_in_possible_matches_(FP)")
          ])
        )

      assert EvalStats.targets(run) == %{"target_found" => 1, "unknown_object" => 1}
    end

    test "measures what an episode cost, and how far the pose it recognised was" do
      run = EvalStats.read(file!([episode(1, "correct", 20), episode(2, "correct", 40)]))

      # Nine tenths of two episodes is the larger of them, by nearest rank.
      assert %{n: 2, mean: 30.0, median: 30.0, p90: 40.0, max: 40.0} =
               EvalStats.metric(run, "num_steps")

      # The recognised pose is a centimetre from the object in x and four in y and
      # z, so just under six centimetres away.
      assert %{mean: error} = EvalStats.metric(run, :pose_error)
      assert_in_delta error, 0.0574, 0.001
    end

    test "reads a vector as numpy writes it, a whole number as `0.`" do
      run =
        EvalStats.read(
          file!([
            "1,correct,20,140,1.5,target_in_possible_matches_(TP),1,0.1," <>
              "[0.  1.5 0. ],[0.  1.5 0. ],[ ]"
          ])
        )

      assert %{mean: error} = EvalStats.metric(run, :pose_error)
      assert error == 0.0
    end

    test "an episode that reported no outcome is unrecorded rather than a failure" do
      run = EvalStats.read(file!(["1,,20,140,1.5,,1,0.1,[0.0 1.0 0.0],[0.0 1.0 0.0],"]))

      assert EvalStats.outcomes(run) == %{"unrecorded" => 1}
      assert EvalStats.exits(run) == %{"unrecorded" => 1}
    end

    test "a run whose episodes carry no seed is read without joining on one" do
      rows = [
        String.replace(episode(1, "correct"), "1,", ","),
        String.replace(episode(2, "confused"), "2,", ",")
      ]

      run = EvalStats.read(file!(rows))

      refute run.seeded?
      assert EvalStats.episodes(run) == 2
    end
  end

  describe "the file itself" do
    test "a quoted field holding commas is one value" do
      [row] = EvalStats.rows_of_csv(@columns <> episode(1, "correct") <> "\n")

      assert row["possible_match_sources"] == "['mug', 'cup']"
      assert row["detected_location"] == "[-0.01 1.46 0.04]"
    end

    test "a run's folder is read as the run inside it" do
      source = file!([episode(7, "correct")])
      folder = Path.join(System.tmp_dir!(), "run_#{System.unique_integer([:positive])}")
      File.mkdir_p!(folder)
      File.cp!(source, Path.join(folder, "eval_stats.csv"))
      on_exit(fn -> File.rm_rf(folder) end)

      run = EvalStats.read(folder)

      assert run.files == [Path.join(folder, "eval_stats.csv")]
      assert run.name == Path.basename(folder) |> String.slice(0, 28)
      assert EvalStats.episodes(run) == 1
    end

    test "a divided run still going is read from its parts" do
      folder = Path.join(System.tmp_dir!(), "divided_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(folder, "parts/a"))
      File.mkdir_p!(Path.join(folder, "parts/b"))

      File.write!(
        Path.join(folder, "parts/a/eval_stats.csv"),
        @columns <> episode(1, "correct") <> "\n"
      )

      File.write!(
        Path.join(folder, "parts/b/eval_stats.csv"),
        @columns <> episode(2, "confused") <> "\n"
      )

      on_exit(fn -> File.rm_rf(folder) end)

      run = EvalStats.read(folder)

      assert length(run.files) == 2
      assert EvalStats.episodes(run) == 2
      assert EvalStats.outcomes(run) == %{"recognised" => 1, "confused" => 1}
    end

    test "a divided run that has merged says each episode once" do
      folder = Path.join(System.tmp_dir!(), "merged_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(folder, "parts/a"))

      File.write!(
        Path.join(folder, "parts/a/eval_stats.csv"),
        @columns <> episode(1, "correct") <> "\n"
      )

      File.write!(Path.join(folder, "eval_stats.csv"), @columns <> episode(1, "correct") <> "\n")
      on_exit(fn -> File.rm_rf(folder) end)

      run = EvalStats.read(folder)

      assert run.files == [Path.join(folder, "eval_stats.csv")]
      assert EvalStats.episodes(run) == 1
    end

    test "a run given as the files of its parts is one run" do
      first = file!([episode(1, "correct")])
      second = file!([episode(2, "confused")])

      run = EvalStats.read([first, second], "divided")

      assert run.name == "divided"
      assert run.files == [first, second]
      assert EvalStats.outcomes(run) == %{"recognised" => 1, "confused" => 1}
    end
  end

  describe "two runs" do
    test "are compared on the episodes they share, and the rest is described" do
      ours = EvalStats.read(file!([episode(1, "correct"), episode(2, "confused")]))

      monty =
        EvalStats.read(
          file!([episode(1, "correct"), episode(2, "correct"), episode(3, "correct")])
        )

      compared = EvalStats.compare(monty, ours)

      assert compared.shared == [1, 2]
      assert compared.only_here == [3]
      assert compared.only_there == []
      assert compared.agreed == 1
      assert compared.disagreed == [2]
    end

    test "measure how far apart the two runs' episodes are" do
      ours = EvalStats.read(file!([episode(1, "correct", 10), episode(2, "correct", 30)]))
      monty = EvalStats.read(file!([episode(1, "correct", 20), episode(2, "correct", 20)]))

      deltas = EvalStats.compare(monty, ours).deltas["num_steps"]

      assert deltas.mean == 0.0
      assert deltas.lower == 1
      assert deltas.higher == 1
      assert deltas.equal == 0
    end

    test "the report names the episode whose outcome differs, and what each said" do
      ours = EvalStats.read(file!([episode(1, "correct"), episode(2, "confused")]), "ours")
      monty = EvalStats.read(file!([episode(1, "correct"), episode(2, "correct")]), "monty")

      report = ours |> then(&EvalStats.report([monty, &1])) |> IO.iodata_to_binary()

      assert report =~ "outcome agrees on 1/2"
      assert report =~ ~r/^2\s+-\s+recognised\s+confused/m
    end
  end

  describe "the command" do
    import ExUnit.CaptureIO

    test "prints the report for the run it is given" do
      path = file!([episode(1, "correct")])

      report = capture_io(fn -> Mix.Task.rerun("monty.compare", [path]) end)

      assert report =~ "per-episode metrics"
      assert report =~ "recognised"
    end

    test "refuses to run without a run to read" do
      assert_raise Mix.Error, ~r/name a run/, fn -> Mix.Task.rerun("monty.compare", []) end
    end
  end
end
