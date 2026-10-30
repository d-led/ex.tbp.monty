defmodule Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandlerTest do
  @moduledoc """
  The CSV Monty leaves behind, held to Monty's own shape.

  The fixtures are the dictionaries Monty's handlers are given — `BASIC` logs
  keyed by episode, then by component — because that is what
  `BasicGraphMatchingLogger` hands this handler, and a fixture that already looked
  like the output would test the writing and not the reading.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler, as: Handler
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("csv_handler")}
  end

  defp basic(mode, episode), do: %{"BASIC" => %{"#{mode}_stats" => %{0 => episode}}}

  defp report(handler, data, dir, mode),
    do: Handler.report_episode(handler, data, dir, 0, mode, %{})

  describe "the file a report writes" do
    test "is named after the mode, as Monty names it", %{dir: dir} do
      episode = %{"LM_0" => %{"primary_performance" => "correct"}}

      {:ok, handler} = report(Handler.new(), basic("train", episode), dir, :train)
      report(handler, basic("eval", episode), dir, :eval)

      assert File.exists?(Path.join(dir, "train_stats.csv"))
      assert File.exists?(Path.join(dir, "eval_stats.csv"))
    end

    test "has one row per learning module, and none for a sensor module", %{dir: dir} do
      episode = %{
        "LM_0" => %{"primary_performance" => "correct"},
        "LM_1" => %{"primary_performance" => "no_match"},
        "SM_0" => %{"step" => 1}
      }

      {:ok, _handler} = report(Handler.new(), basic("train", episode), dir, :train)

      [_header | rows] =
        Path.join(dir, "train_stats.csv") |> File.read!() |> String.split("\n", trim: true)

      assert length(rows) == 2
      assert Enum.any?(rows, &String.contains?(&1, "LM_0"))
      assert Enum.any?(rows, &String.contains?(&1, "LM_1"))
      refute Enum.any?(rows, &String.contains?(&1, "SM_0"))
    end

    test "writes its header once, however many episodes are appended", %{dir: dir} do
      episode = %{"LM_0" => %{"primary_performance" => "correct"}}
      data = basic("train", episode)

      {:ok, handler} = report(Handler.new(), data, dir, :train)
      {:ok, _handler} = report(handler, data, dir, :train)

      lines = Path.join(dir, "train_stats.csv") |> File.read!() |> String.split("\n", trim: true)

      assert Enum.count(lines, &String.starts_with?(&1, "primary_performance,")) == 1
      assert length(lines) == 3
    end

    test "renames the file it finds, so a new run does not grow the last one's numbers", %{
      dir: dir
    } do
      path = Path.join(dir, "train_stats.csv")
      File.write!(path, "from the last run\n")

      episode = %{"LM_0" => %{"primary_performance" => "correct"}}
      {:ok, _handler} = report(Handler.new(), basic("train", episode), dir, :train)

      assert File.read!(Path.join(dir, "train_stats_old.csv")) == "from the last run\n"
      refute File.read!(path) =~ "from the last run"
    end
  end

  describe "the columns" do
    test "are Monty's, in Monty's order, with the module id last" do
      rows = [{"LM_0", %{"primary_performance" => "correct", "most_likely_object" => "mug"}}]

      assert Handler.columns(rows) == [
               "primary_performance",
               "stepwise_performance",
               "num_steps",
               "rotation_error",
               "result",
               "most_likely_object",
               "primary_target_object",
               "stepwise_target_object",
               "highest_evidence",
               "time",
               "symmetry_evidence",
               "monty_steps",
               "monty_matching_steps",
               "individual_ts_performance",
               "individual_ts_reached_at_step",
               "primary_target_position",
               "primary_target_rotation_euler",
               "most_likely_rotation",
               "lm_id"
             ]
    end

    test "leave out what the run never believed, and keep the rest in Monty's order" do
      rows = [{"LM_0", %{"primary_performance" => "correct", "extra_stat" => 3}}]
      columns = Handler.columns(rows)

      refute "most_likely_object" in columns
      assert Enum.take(columns, 2) == ["primary_performance", "stepwise_performance"]
      assert Enum.take(columns, -2) == ["extra_stat", "lm_id"]
    end

    test "a stat the run did not compute is empty, not zero" do
      row = Handler.row("LM_0", %{"primary_performance" => "correct"})

      assert String.starts_with?(row, "correct,,,,,,")
      assert String.ends_with?(row, ",LM_0")
    end
  end

  describe "a cell" do
    test "is written the way pandas writes one, so two files can be diffed" do
      columns = Handler.columns([{"LM_0", %{"result" => true}}])

      expected = fn written ->
        Enum.map_join(columns, ",", fn
          "result" -> written
          "lm_id" -> "LM_0"
          _column -> ""
        end)
      end

      for {value, written} <- [
            {nil, ""},
            {"correct", "correct"},
            {12, "12"},
            {1.5, "1.5"},
            {true, "True"},
            {false, "False"},
            {:no_match, "no_match"},
            {[0.1, 0.2], ~s("[0.1, 0.2]")},
            {["mug", "bowl"], ~s("['mug', 'bowl']")}
          ] do
        assert Handler.row("LM_0", %{"result" => value}, columns) == expected.(written),
               "#{inspect(value)} is written #{inspect(written)}"
      end
    end

    test "is quoted when it holds a comma, which a list does" do
      row = Handler.row("LM_0", %{"primary_target_position" => [0.1, 0.2]})

      assert row =~ ~s("[0.1, 0.2]")
    end
  end
end
