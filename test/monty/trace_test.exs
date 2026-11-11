defmodule Monty.TraceTest do
  @moduledoc """
  The experiment's own words are a level of their own, below `debug`.

  Monty's Python says "did not recognize an object yet" on every step of every
  episode, and this port says it in the same place. A console reading a
  twenty-thousand-step run is a console nobody can read, so those lines are off
  unless a deployment asks for them, and everything else in the application
  keeps its ordinary level.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Monty.Test.Tmp
  alias Monty.Trace

  # Captured at `:debug`, which is what a development console shows: what the
  # tests below distinguish is the trace's own switch, not the console's level.
  # The suite's own level is `:warning`, so it is raised for the length of a test
  # — otherwise `Logger` drops the line before any capture sees it, and a test
  # that means "the trace is off" would pass for the wrong reason.
  @capture [level: :debug]

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
  end

  describe "the experiment's own words" do
    test "are not said to a console that did not ask for them" do
      Tmp.app_env(:ex_tbp_monty_core, :experiment_trace, false)

      assert capture_log(@capture, fn -> Trace.trace("mug recognised") end) == ""
    end

    test "are said, at debug, when the deployment asks" do
      Tmp.app_env(:ex_tbp_monty_core, :experiment_trace, true)

      assert capture_log(@capture, fn -> Trace.trace("mug recognised") end) =~ "mug recognised"
    end

    # The reason a line is a function: a step that is not being traced must not
    # build the string — inspecting every hypothesis of every step of every run
    # was most of what a drawing of a chart cost, for a line nobody read.
    test "a line nobody asked for is not built at all" do
      Tmp.app_env(:ex_tbp_monty_core, :experiment_trace, false)

      capture_log(@capture, fn ->
        Trace.trace(fn ->
          send(self(), :built)
          "expensive"
        end)
      end)

      refute_received :built
    end

    test "and a line that was asked for is" do
      Tmp.app_env(:ex_tbp_monty_core, :experiment_trace, true)

      assert capture_log(@capture, fn -> Trace.trace(fn -> "expensive" end) end) =~ "expensive"
    end

    # `MONTY_TRACE=1` is how a shell says yes, and it arrives as a string.
    test "a shell's yes counts as one" do
      Tmp.app_env(:ex_tbp_monty_core, :experiment_trace, "1")

      assert Trace.enabled?()
    end
  end

  # One home for the experiment's words, so that a change of mind is a change in
  # one file: the ported modules do not log at a level the console always shows.
  describe "the ported modules" do
    test "say nothing at info or debug; the trace is the only way they talk" do
      offenders =
        "packages/ex_tbp_monty_core/lib/monty/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 == "packages/ex_tbp_monty_core/lib/monty/trace.ex"))
        |> Enum.filter(fn file ->
          File.read!(file) =~ ~r/Logger\.(info|debug)\(/
        end)

      assert offenders == [], """
      These modules log at a level a console always shows, which is what made a
      run unreadable:\n#{Enum.map_join(offenders, "\n", &"  #{&1}")}
      """
    end
  end
end
