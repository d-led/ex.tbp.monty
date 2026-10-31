defmodule Monty.Studio.LoggingTest do
  @moduledoc """
  What a run logs with is the config's answer: the classes it names, and the ones
  this port has.

  Monty builds its logger out of its own config — one `monty_data_logger` with the
  handlers it hands each episode to — so a config written for Monty has to be
  enough here too. What the config names and what this port has are two different
  questions, and a class that is named but not ported is skipped *by name*: a run
  that silently logs less than its config asks for is a run whose numbers nobody
  can trust.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.GraphMatchingLoggers.BasicGraphMatchingLogger
  alias Monty.Frameworks.Loggers.MontyHandlers.{BasicCSVStatsHandler, DetailedJSONHandler}
  alias Monty.Studio.{Logging, Run, Setup}

  @csv_and_json """
  # @package _global_

  experiment:
    config:
      logging:
        output_dir: /tmp/monty_runs
        run_name: a_run
        monty_data_logger:
          _target_: tbp.monty.frameworks.loggers.graph_matching_loggers.BasicGraphMatchingLogger
          handlers:
            - _target_: tbp.monty.frameworks.loggers.monty_handlers.BasicCSVStatsHandler
            - _target_: tbp.monty.frameworks.loggers.monty_handlers.DetailedJSONHandler
              detailed_save_per_episode: true
  """

  # The group Monty's benchmark experiments include: CSV inside the run, and
  # wandb beside it.
  @csv_and_wandb """
  # @package _global_

  experiment:
    config:
      logging:
        monty_data_logger:
          _target_: tbp.monty.frameworks.loggers.graph_matching_loggers.BasicGraphMatchingLogger
          handlers:
            - _target_: tbp.monty.frameworks.loggers.monty_handlers.BasicCSVStatsHandler
            - _target_: tbp.monty.frameworks.loggers.wandb_handlers.WandbWrapper
              resume_wandb_run: false
              wandb_handlers:
                - _target_: tbp.monty.frameworks.loggers.wandb_handlers.BasicWandbTableStatsHandler
  """

  # The tutorial's group: a logger that keeps no statistics at all.
  @silent """
  # @package _global_

  experiment:
    config:
      logging:
        monty_data_logger:
          _target_: tbp.monty.frameworks.loggers.exp_logger.BaseMontyLogger
          handlers: []
  """

  @nothing_named """
  # @package _global_

  experiment:
    config:
      n_train_epochs: 1
  """

  defp plan(yaml) do
    {:ok, setup} = Setup.from_text(yaml)
    Logging.open(setup)
  end

  test "builds the logger and the handlers the config names, with their keywords" do
    assert %{logger: %BasicGraphMatchingLogger{handlers: [csv, json]}, notes: []} =
             plan(@csv_and_json)

    assert %BasicCSVStatsHandler{} = csv

    assert %DetailedJSONHandler{detailed_save_per_episode: true, detailed_episodes_to_save: :all} =
             json
  end

  test "says which classes this port does not have, and logs with the ones it does" do
    assert %{
             logger: %BasicGraphMatchingLogger{handlers: [%BasicCSVStatsHandler{}]} = logger,
             notes: notes
           } =
             plan(@csv_and_wandb)

    assert logger.handlers |> length() == 1

    assert notes == [
             "logging: tbp.monty.frameworks.loggers.wandb_handlers.py::WandbWrapper is not ported yet; skipped"
           ]
  end

  test "a config that asks for silent logging gets a logger with no handlers" do
    assert %{logger: %Monty.Frameworks.Loggers.ExpLogger.BaseMontyLogger{handlers: []}, notes: []} =
             plan(@silent)
  end

  test "a config that names no logger writes nothing, and says so" do
    assert %{logger: nil, notes: [note]} = plan(@nothing_named)

    assert note =~ "names no data logger"
  end

  test "reporting into a plan with no logger is skipped rather than an error" do
    assert {:skipped, %{logger: nil}} =
             Logging.report(%{logger: nil, notes: []}, run(), "/tmp/runs")
  end

  # The run a plan is reported against is not read when there is no logger, which
  # is exactly the case this covers: nothing about a run makes a silent config
  # write a file.
  defp run do
    %Run{model: nil, model_id: "unused", setup: nil, interface: nil, episode_seed: 0}
  end
end
