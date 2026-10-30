defmodule Monty.Frameworks.Loggers.MontyHandlers.DetailedJSONHandlerTest do
  @moduledoc """
  The episode in full, in the two files Monty offers.

  The interesting parts are not the writing but the keying: which episode id a
  record is filed under, which of the two detailed pools wins, and that a
  single-file run renames what it found exactly once.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.MontyHandlers.DetailedJSONHandler, as: Handler
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("detailed_json")}
  end

  # Monty's log dictionary: BASIC keyed by local episode, DETAILED the pool the
  # detailed logger filled.
  defp logs(basic, detailed, mode \\ "train") do
    %{"BASIC" => %{"#{mode}_stats" => basic}, "DETAILED" => detailed}
  end

  defp report(handler, data, dir, local, mode, episodes_to_total) do
    Handler.report_episode(handler, data, dir, local, mode, episodes_to_total)
  end

  describe "saving every episode in one file" do
    test "appends one JSON object per episode, keyed by the run's episode id", %{dir: dir} do
      data = logs(%{0 => %{"num_steps" => 5}}, %{0 => %{"lm" => %{"steps" => [1, 2]}}})

      {:ok, handler} = report(Handler.new(), data, dir, 0, :train, %{0 => 3})
      {:ok, _handler} = report(handler, data, dir, 0, :train, %{0 => 4})

      records =
        Path.join(dir, "detailed_run_stats.json")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(records) == 2

      assert [%{"3" => %{"num_steps" => 5, "lm" => %{"steps" => [1, 2]}}}, %{"4" => _}] =
               Enum.map(records, &Jason.decode!/1)
    end

    test "renames the file it found once, not at every episode", %{dir: dir} do
      path = Path.join(dir, "detailed_run_stats.json")
      File.write!(path, ~s({"from":"the last run"}\n))

      data = logs(%{0 => %{"num_steps" => 5}}, %{0 => %{}})
      {:ok, handler} = report(Handler.new(), data, dir, 0, :train, %{0 => 0})
      {:ok, _handler} = report(handler, data, dir, 0, :train, %{0 => 1})

      assert File.read!(Path.join(dir, "detailed_run_stats_old.json")) ==
               ~s({"from":"the last run"}\n)

      refute File.read!(path) =~ "the last run"
    end
  end

  describe "saving one file per episode" do
    test "writes the episode under its own name", %{dir: dir} do
      handler = Handler.new(detailed_save_per_episode: true)
      data = logs(%{0 => %{"num_steps" => 5}}, %{0 => %{"lm" => %{"steps" => [1]}}})

      {:ok, _handler} = report(handler, data, dir, 0, :train, %{0 => 3})

      path = Path.join([dir, "detailed_run_stats", "episode_000003.json"])

      assert %{"3" => %{"num_steps" => 5, "lm" => %{"steps" => [1]}}} =
               Jason.decode!(File.read!(path))
    end
  end

  describe "which episodes are saved" do
    test "only the ones the handler was asked for", %{dir: dir} do
      handler = Handler.new(detailed_episodes_to_save: [7])
      data = logs(%{0 => %{"num_steps" => 5}}, %{0 => %{}})

      {:ok, _handler} = report(handler, data, dir, 0, :train, %{0 => 3})

      refute File.exists?(Path.join(dir, "detailed_run_stats.json"))
    end
  end

  describe "the detailed pool" do
    test "falls back to the run's episode id when the local one is absent", %{dir: dir} do
      data = logs(%{0 => %{"num_steps" => 5}}, %{5 => %{"lm" => %{"steps" => [9]}}})

      {:ok, _handler} = report(Handler.new(), data, dir, 0, :train, %{0 => 5})

      assert %{"5" => %{"lm" => %{"steps" => [9]}}} =
               Path.join(dir, "detailed_run_stats.json") |> File.read!() |> Jason.decode!()
    end

    test "an episode with no BASIC stats is a reason, not an empty file", %{dir: dir} do
      data = logs(%{}, %{0 => %{}})

      assert {:error, {:no_basic_stats, 0}} =
               report(Handler.new(), data, dir, 0, :train, %{0 => 0})

      refute File.exists?(Path.join(dir, "detailed_run_stats.json"))
    end
  end
end
