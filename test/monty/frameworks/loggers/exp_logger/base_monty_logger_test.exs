defmodule Monty.Frameworks.Loggers.ExpLogger.BaseMontyLoggerTest do
  @moduledoc """
  The logger a concrete logger is built from: it holds handlers, and an event
  leaves it as it was.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.ExpLogger.BaseMontyLogger
  alias Monty.Test.ClosingHandler

  describe "an event" do
    test "changes nothing, because a base logger computes nothing" do
      logger = BaseMontyLogger.new()

      assert {:ok, ^logger} = BaseMontyLogger.pre_episode(logger, %{}, "/tmp", :model)
      assert {:ok, ^logger} = BaseMontyLogger.post_epoch(logger, %{}, "/tmp", :model)
      assert {:ok, ^logger} = BaseMontyLogger.flush(logger)
    end
  end

  describe "the handlers" do
    test "are the ones it was made with, and one handler is still a list" do
      assert BaseMontyLogger.new(%ClosingHandler{}).handlers == [%ClosingHandler{}]
      assert BaseMontyLogger.new([%ClosingHandler{}, %ClosingHandler{}]).handlers |> length() == 2
    end

    test "are all closed when the logger is" do
      logger = BaseMontyLogger.new([%ClosingHandler{}, %ClosingHandler{}])

      assert {:ok, ^logger} = BaseMontyLogger.close(logger, %{}, "/tmp", :model)

      assert_received {:closed, ClosingHandler}
      assert_received {:closed, ClosingHandler}
    end
  end
end
