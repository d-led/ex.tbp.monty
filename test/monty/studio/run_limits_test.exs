defmodule Monty.Studio.RunLimitsTest do
  @moduledoc """
  What a run may hold, and what happens when it holds more.

  The watcher is driven with a number it is handed rather than with a real
  runaway: a case that needs a machine to swap out is not a case anybody runs.
  See `Monty.Studio.RunLimits` for the two ceilings and the gaps between them.
  """

  use ExTbpMonty.DataCase

  alias Monty.Studio.{RunLimits, Settings}

  # A watcher's clock and its ceiling are its own, but the settings it falls back
  # to are read from a table: each test starts from it.
  setup do
    Settings.forget()
    :ok
  end

  describe "a process's heap ceiling" do
    # Monty's own two numbers: a megabyte of heap is 131 072 words on a 64-bit
    # VM, and the flag has to kill rather than report, or a runaway process
    # survives its own warning.
    test "is the words a process may hold, and it kills" do
      assert %{size: 131_072, kill: true, error_logger: true} = RunLimits.heap_flag(1)
    end

    test "scales with the megabytes it is given" do
      assert %{size: size} = RunLimits.heap_flag(1_024)
      assert size == 1_024 * 131_072
    end
  end

  describe "a ceiling and what is held" do
    test "is passed only by more than it allows" do
      allowed = 6_144

      refute RunLimits.exceeded?(allowed, 6_144 * 1024 * 1024)
      assert RunLimits.exceeded?(allowed, 6_144 * 1024 * 1024 + 1)
    end

    test "reads a machine's total as whole megabytes" do
      assert RunLimits.megabytes(3 * 1024 * 1024 * 1024) == 3_072
    end
  end

  describe "watching a run" do
    @tag timeout: 5_000
    test "stops the run once the machine holds more than its ceiling" do
      ceiling = 1_024
      this_test = self()

      # One byte past the ceiling, from the first sample on.
      held = ceiling * 1024 * 1024 + 1

      RunLimits.watch("a-run",
        held: fn -> held end,
        allowed: ceiling,
        stop: fn run_id -> send(this_test, {:stop, run_id}) end,
        interval: 1
      )

      assert_receive {:stop, "a-run"}, 2_000
    end

    @tag timeout: 5_000
    test "leaves a run alone while it holds less" do
      this_test = self()

      RunLimits.watch("a-run",
        held: fn -> 1 end,
        allowed: 1_024,
        stop: fn run_id -> send(this_test, {:stop, run_id}) end,
        interval: 1
      )

      refute_receive {:stop, _run_id}, 50
    end

    test "the ceiling a run is given is the one the settings say" do
      assert RunLimits.allowed_mb() == Settings.get(RunLimits.vm_setting())
    end
  end

  # A heap ceiling is enforced by the emulator: the process it kills is not
  # raising, so nothing is said by the process itself. A run that stepped in the
  # reporting process therefore ended with no summary and its log stopping at a
  # step (§2.35), which is why the work is a child the caller watches.
  describe "a step whose process ends instead of answering" do
    test "answers what the step answered" do
      assert {:ok, :a_step} = RunLimits.watch_step(fn -> :a_step end)
    end

    # What a heap ceiling does to the process holding the model: the exit reaches
    # the caller of its call, and an uncaught one ends the VM (§2.35).
    test "catches the exit a killed worker leaves in its caller" do
      assert {:error, {:shutdown, {GenServer, :call, [:a_server, :step]}}} =
               RunLimits.watch_step(fn ->
                 exit({:shutdown, {GenServer, :call, [:a_server, :step]}})
               end)
    end

    test "lets a crash through, because a crash has a stacktrace to read" do
      assert_raise RuntimeError, "the module had no graph", fn ->
        RunLimits.watch_step(fn -> raise "the module had no graph" end)
      end
    end
  end

  describe "what is said about a run that stopped" do
    test "attributes a kill to the ceiling, and names the setting that set it" do
      sentence = RunLimits.stopped_sentence(:killed)

      assert sentence =~ "heap ceiling"
      assert sentence =~ RunLimits.heap_setting()
      assert sentence =~ "nothing it had not already written is kept"
    end

    test "shows a crash where it was raised" do
      assert RunLimits.stopped_sentence({%RuntimeError{message: "no graph"}, []}) =~ "no graph"
    end

    # A step worker killed mid-step takes the caller's `GenServer.call` with it,
    # and the request is a step's whole observation — the sentence names the
    # worker and points at the line the worker's own death was logged in.
    test "does not print the step a worker died carrying" do
      sentence =
        RunLimits.stopped_sentence(
          {:shutdown,
           {GenServer, :call,
            [
              {:via, Registry, {Monty.Runtime.Registry, {:step, "studio-1"}}},
              {:step, %{"rgba" => :frame}}
            ]}}
        )

      assert sentence =~ "stopped mid-call"
      assert sentence =~ "logged above"
      refute sentence =~ "rgba"
    end
  end
end
