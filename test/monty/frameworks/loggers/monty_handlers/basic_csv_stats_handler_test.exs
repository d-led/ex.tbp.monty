defmodule Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandlerTest do
  @moduledoc """
  The CSV Monty leaves behind, held to its own shape.

  Monty's `eval_stats.csv` is the artefact a comparison reads, so the things
  tested here are the things a diff would trip over if they moved: the column
  order, which column the module id is in, a header written once, and an existing
  file renamed rather than appended to.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler, as: Handler
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("csv_handler")}
  end

  test "the columns are Monty's, in Monty's order, with the module id last" do
    header = Handler.header()

    assert String.starts_with?(
             header,
             "primary_performance,stepwise_performance,num_steps,rotation_error,result," <>
               "most_likely_object,primary_target_object"
           )

    assert String.ends_with?(header, ",most_likely_rotation,lm_id")
  end

  test "a column this run did not compute is a blank cell, not a zero" do
    row = Handler.row("LM_0", %{"num_steps" => 12, "result" => "mug"})
    cells = String.split(row, ",")

    assert Enum.at(cells, 2) == "12"
    assert Enum.at(cells, 4) == "mug"
    assert Enum.at(cells, 5) == ""
    assert List.last(cells) == "LM_0"
  end

  test "a key Monty does not name keeps its own column after the named ones" do
    header = Handler.header(["monty_episode"])
    assert String.ends_with?(header, ",most_likely_rotation,lm_id,monty_episode")

    assert String.ends_with?(Handler.row("LM_0", %{"monty_episode" => 3}), ",LM_0,3")
  end

  test "an episode's modules are two rows, and the header is written once", %{dir: dir} do
    path = Path.join(dir, "eval_stats.csv")
    episode = %{"LM_0" => %{"num_steps" => 5}, "LM_1" => %{"num_steps" => 7}}

    handler = Handler.new(path)
    {:ok, handler} = Handler.report(handler, episode)
    {:ok, handler} = Handler.report(handler, episode)
    assert :ok = Handler.close(handler)

    lines = path |> File.read!() |> String.split("\n", trim: true)

    # one header, then two rows per episode
    assert length(lines) == 5
    assert hd(lines) == Handler.header()
    assert Enum.at(lines, 1) == Handler.row("LM_0", %{"num_steps" => 5})
  end

  test "an existing file is renamed, not appended to", %{dir: dir} do
    path = Path.join(dir, "eval_stats.csv")
    File.write!(path, "last run's numbers\n")

    handler = Handler.new(path)
    {:ok, _handler} = Handler.report(handler, %{"LM_0" => %{"num_steps" => 5}})

    assert File.read!(Path.join(dir, "eval_stats_old.csv")) == "last run's numbers\n"
    refute File.read!(path) =~ "last run"
  end
end
