defmodule Monty.Frameworks.Loggers.ExpLogger.TestLoggerTest do
  @moduledoc """
  A logger that writes down what reached it, and the file it leaves behind —
  Monty's way of asking "was the event called?" without standing up a logger that
  computes.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.ExpLogger.TestLogger
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("test_logger")}
  end

  test "an event is written down, in the order it arrived" do
    logger = TestLogger.new()

    {:ok, logger} = TestLogger.post_epoch(logger, %{}, nil, :model)
    {:ok, logger} = TestLogger.pre_episode(logger, %{}, nil, :model)

    assert TestLogger.events(logger) == [:post_epoch, :pre_episode]
  end

  test "closing writes the events to fake_log.json", %{dir: dir} do
    {:ok, logger} = TestLogger.pre_episode(TestLogger.new(), %{}, dir, :model)

    assert {:ok, _logger} = TestLogger.close(logger, %{}, dir, :model)
    assert File.read!(Path.join(dir, "fake_log.json")) == ~s(["pre_episode"])
  end
end
