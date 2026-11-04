defmodule ExTbpMonty.Desktop.ParentWatchTest do
  # These hold operating-system processes, which are the machine's.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Desktop.ParentWatch

  describe "a server whose starter is gone" do
    test "is stopped, so it cannot hold the port and the database unseen" do
      starter = start_something_that_lives_a_while()
      test = self()

      {:ok, _watch} =
        ParentWatch.start_link(
          parent: starter,
          interval_ms: 50,
          on_gone: fn -> send(test, :stopped) end
        )

      refute_receive :stopped, 200, "a server was stopped while its starter was still there"

      stop(starter)

      assert_receive :stopped, 2_000
    end

    test "is left alone while its starter is alive" do
      starter = start_something_that_lives_a_while()
      test = self()

      {:ok, _watch} =
        ParentWatch.start_link(
          parent: starter,
          interval_ms: 50,
          on_gone: fn -> send(test, :stopped) end
        )

      refute_receive :stopped, 400

      stop(starter)
    end

    test "is not watched at all when there is nobody to watch" do
      assert ParentWatch.start_link(parent: nil) == :ignore
    end
  end

  describe "the process that started this one" do
    test "is read as a pid that is not this one" do
      parent = ParentWatch.parent_pid()

      assert is_integer(parent)
      assert parent != String.to_integer(System.pid())
    end

    test "counts as alive while it is running" do
      assert ParentWatch.alive?(ParentWatch.parent_pid())
    end

    test "counts as gone once it is not" do
      pid = start_something_that_lives_a_while()
      stop(pid)

      refute gone_within(pid, 2_000)
    end
  end

  # `kill -0` still answers for a process that died a moment ago and has not been
  # reaped, so the answer is only "gone" once it is really gone.
  defp gone_within(pid, budget) when budget <= 0, do: ParentWatch.alive?(pid)

  defp gone_within(pid, budget) do
    if ParentWatch.alive?(pid) do
      Process.sleep(25)
      gone_within(pid, budget - 25)
    else
      false
    end
  end

  # A process of the operating system's, not ours: the watch has to work on what
  # `kill` sees. Its output goes to `/dev/null`, or `System.cmd/2` would wait for
  # the pipe to close and block for as long as the process lives.
  defp start_something_that_lives_a_while do
    {output, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = String.to_integer(String.trim(output))
    # Already gone in some tests, and a complaint about that is not a failure.
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true) end)
    pid
  end

  defp stop(pid), do: System.cmd("kill", ["-9", Integer.to_string(pid)])
end
