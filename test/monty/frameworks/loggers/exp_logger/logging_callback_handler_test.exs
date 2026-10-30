defmodule Monty.Frameworks.Loggers.ExpLogger.LoggingCallbackHandlerTest do
  @moduledoc """
  One event, every logger — the fan-out Monty runs a whole experiment through.

  The loggers under test are the real ones: `TestLogger` writes down what reached
  it, so "was `post_epoch` called on both loggers, in order?" is answered by what
  they recorded rather than by a spy.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.ExpLogger.BaseMontyLogger
  alias Monty.Frameworks.Loggers.ExpLogger.LoggingCallbackHandler
  alias Monty.Frameworks.Loggers.ExpLogger.TestLogger
  alias Monty.Test.Tmp

  setup do
    {:ok, dir: Tmp.dir("exp_logger")}
  end

  defp handler(loggers, dir), do: LoggingCallbackHandler.new(loggers, :model, dir)

  describe "a logger list" do
    test "is called on every event, in the order the events arrived", %{dir: dir} do
      handler = LoggingCallbackHandler.new(TestLogger.new(), :model, dir)

      {:ok, handler} = LoggingCallbackHandler.pre_episode(handler, %{})
      {:ok, handler} = LoggingCallbackHandler.post_train(handler, %{})

      [_logger] = handler.loggers
      assert TestLogger.events(hd(handler.loggers)) == [:pre_episode, :post_train]
    end

    test "is one name per line, as Monty's logger_list prints it" do
      handler = handler([TestLogger.new(), BaseMontyLogger.new()], nil)

      assert LoggingCallbackHandler.logger_list(handler) ==
               "Monty.Frameworks.Loggers.ExpLogger.TestLogger\n" <>
                 "Monty.Frameworks.Loggers.ExpLogger.BaseMontyLogger"
    end

    test "may be one logger, which is still a list", %{dir: dir} do
      handler = handler(TestLogger.new(), dir)

      assert [%TestLogger{}] = handler.loggers
    end
  end

  describe "the end of a run" do
    test "closes every logger, which is when a logger writes what it collected", %{dir: dir} do
      handler = LoggingCallbackHandler.new(TestLogger.new(), :model, dir)
      {:ok, handler} = LoggingCallbackHandler.pre_episode(handler, %{})
      {:ok, _handler} = LoggingCallbackHandler.close(handler, %{})

      assert File.read!(Path.join(dir, "fake_log.json")) == ~s(["pre_episode"])
    end
  end

  describe "a logger that fails" do
    test "stops the fan-out with its reason, rather than being skipped", %{dir: dir} do
      failing = Monty.Test.FailingLogger.new(:disk_full)
      handler = handler([failing, TestLogger.new()], dir)

      assert LoggingCallbackHandler.call_event(handler, :pre_episode, %{}) ==
               {:error, :disk_full}
    end
  end
end
