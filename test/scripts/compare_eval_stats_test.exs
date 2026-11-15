defmodule Scripts.CompareEvalStatsTest do
  @moduledoc """
  The report a reader gets when two runs' `eval_stats.csv` are put side by side.

  The script is the tool a comparison is made with, so what is asserted here is
  what a reader is told: how many episodes the two runs share, where they
  disagree, and that a short run against a long one is a comparison rather than
  an error.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/compare_eval_stats.py", __DIR__)

  @header "episode_seed,primary_performance,num_steps,monty_steps,time,TFNP," <>
            "num_possible_matches,rotation_error,detected_location,primary_target_position\n"

  defp run!(rows) do
    path =
      Path.join(System.tmp_dir!(), "compare_eval_stats_#{System.unique_integer([:positive])}.csv")

    File.write!(path, @header <> Enum.join(rows, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp episode(seed, performance, steps \\ 20) do
    tfnp =
      case performance do
        "correct" -> "target_in_possible_matches_(TP)"
        "confused" -> "target_in_possible_matches_(TP)"
        _none -> "target_not_matched_(FN)"
      end

    "#{seed},#{performance},#{steps},#{steps * 7},1.5,#{tfnp},1,0.1,[0.0 0.0 0.0],[0.0 0.0 0.1]"
  end

  defp report(paths) do
    {out, 0} = System.cmd("python3", [@script | paths], stderr_to_stdout: true)
    out
  end

  test "names the episodes two runs agree on, and the one they do not" do
    ours = run!([episode(1, "correct"), episode(2, "confused"), episode(3, "correct")])
    monty = run!([episode(1, "correct"), episode(2, "correct"), episode(3, "correct")])

    report = report([ours, monty])

    assert report =~ "outcome agrees on 2/3"
    assert report =~ ~r/^2\s+\S*\s*confused\s+recognised/m
  end

  test "a run of three episodes against a run of two is a comparison of the two they share" do
    ours = run!([episode(1, "correct"), episode(2, "correct")])
    monty = run!([episode(1, "correct"), episode(2, "correct"), episode(3, "correct")])

    report = report([monty, ours])

    assert report =~ "2 shared episodes"
    assert report =~ "1 only in"
    assert report =~ "outcome agrees on 2/2"
  end

  test "counts how each episode ended, not only whether it was right" do
    ours = run!([episode(1, "correct"), episode(2, "pose_time_out"), episode(3, "no_match")])

    report = report([ours])

    assert report =~ "pose_not_converged"
    assert report =~ "steps_exhausted"
  end
end
