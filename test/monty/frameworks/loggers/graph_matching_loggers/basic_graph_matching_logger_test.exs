defmodule Monty.Frameworks.Loggers.GraphMatchingLoggers.BasicGraphMatchingLoggerTest do
  @moduledoc """
  The pool an episode fills, and the handlers it is handed to.

  The handler under test is the CSV one, because that is what the pool is for: an
  episode is only logged if a file comes out of it that says what the model did.
  The model is a coordinator state, which is the value this port hands a logger in
  place of Monty's model object.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.GraphMatchingLoggers.BasicGraphMatchingLogger, as: Logger
  alias Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Runtime.Step.State
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("graph_matching_logger")}
  end

  # A module that recognised the object it was asked about, posed exactly as it
  # was placed — the shape of a good episode.
  defp lm(overrides \\ []) do
    found =
      %{
        graph_id_to_target: %{"mug_graph" => MapSet.new(["mug"])},
        target_to_graph_id: %{"mug" => MapSet.new(["mug_graph"])},
        primary_target: "mug",
        primary_target_rotation_quat: [0.0, 0.0, 0.0, 1.0],
        terminal_state: "match",
        detected_object: "mug_graph",
        possible_matches: ["mug_graph"],
        buffer: buffer(%{"detected_rotation_quat" => [0.0, 0.0, 0.0, 1.0], "time" => [1, 3]})
      }

    struct(EvidenceGraphLM, Map.merge(found, Map.new(overrides)))
  end

  defp buffer(stats) do
    %{
      FeatureAtLocationBuffer.new()
      | on_object: [1],
        locations: [[0.1, 0.0, 0.0]],
        stats: Map.merge(FeatureAtLocationBuffer.new().stats, stats)
    }
  end

  defp model(lms, overrides \\ []) do
    spec = %{
      learning_modules:
        lms
        |> Enum.with_index()
        |> Enum.map(fn {lm, index} ->
          %{id: :"lm_#{index}", module: EvidenceGraphLM, state: lm}
        end),
      step: 12,
      matching_steps: 9,
      experiment_mode: :train
    }

    struct(State, Map.merge(Map.merge(%{model_id: :logging}, spec), Map.new(overrides)))
  end

  defp episode_args do
    %{
      "train_episodes" => 0,
      "episode_seed" => 7,
      "target" => %{"object" => "mug", "position" => [0.1, 0.0, 0.0], "scale" => [1.0]}
    }
  end

  describe "the pool an episode fills" do
    test "holds each module's stats, the target, and the run's counts" do
      {:ok, logger} = Logger.update_episode_data(Logger.new(), episode_args(), model([lm()]))
      basic = Logger.data(logger)["BASIC"]

      assert %{
               "primary_performance" => "correct",
               "monty_steps" => 12,
               "monty_matching_steps" => 9
             } = basic["train_stats"][0]["LM_0"]

      assert basic["train_targets"][0]["primary_target_object"] == "mug"
      assert basic["train_timing"][0]["episode_seed"] == 7
      assert basic["train_overall_stats"][0]["overall/num_episodes"] == 1
    end

    test "is handed to the handler, and the next episode starts empty", %{dir: dir} do
      logger = Logger.new(BasicCSVStatsHandler.new())

      {:ok, logger} = Logger.post_episode(logger, episode_args(), dir, model([lm()]))

      csv = Path.join(dir, "train_stats.csv") |> File.read!()
      assert csv =~ "LM_0"
      assert csv =~ "correct"

      # Monty's `flush`: the file has the episode, so the pool does not.
      assert Logger.data(logger)["BASIC"]["train_stats"] == %{}
    end

    test "is written as an evaluation until the coordinator is told otherwise", %{dir: dir} do
      logger = Logger.new(BasicCSVStatsHandler.new())

      {:ok, _logger} =
        Logger.post_episode(logger, episode_args(), dir, model([lm()], experiment_mode: nil))

      assert File.exists?(Path.join(dir, "eval_stats.csv"))
    end
  end

  describe "the run's figures" do
    test "are one hundred percent after an episode that recognised the object" do
      {:ok, logger} = Logger.update_episode_data(Logger.new(), episode_args(), model([lm()]))
      overall = Logger.formatted_overall_stats(logger, :train, 0)

      assert overall["overall/percent_correct"] == 100.0
      assert overall["overall/num_episodes"] == 1
      assert overall["episode/correct"] == true
      assert overall["overall/avg_rotation_error"] == 0.0
    end

    test "count every module as well as the episode" do
      missed = lm(possible_matches: [], detected_object: nil)

      {:ok, logger} =
        Logger.update_episode_data(Logger.new(), episode_args(), model([lm(), missed]))

      overall = Logger.formatted_overall_stats(logger, :train, 0)

      # The model recognised the object; one of its two modules did not.
      assert overall["overall/percent_correct"] == 100.0
      assert overall["overall/percent_correct_per_lm"] == 50.0
      assert overall["overall/percent_no_match_per_lm"] == 50.0
    end

    test "leave a mean of nothing empty rather than zero" do
      off_object = lm(buffer: %{buffer(%{"detected_rotation_quat" => nil}) | on_object: [0]})

      {:ok, logger} =
        Logger.update_episode_data(Logger.new(), episode_args(), model([off_object]))

      overall = Logger.formatted_overall_stats(logger, :train, 0)

      assert overall["overall/avg_rotation_error"] == nil
      assert overall["overall/percent_correct"] == 0.0
      assert overall["episode/correct"] == false
    end
  end

  describe "what is reported per module" do
    test "is the module's own view of the episode" do
      {:ok, logger} = Logger.update_episode_data(Logger.new(), episode_args(), model([lm()]))
      overall = Logger.formatted_overall_stats(logger, :train, 0)

      assert overall["LM_0/episode/steps_to_individual_ts"] == nil
      assert overall["episode/lm_steps"] == 0
      assert overall["episode/monty_steps"] == 12
    end
  end
end
