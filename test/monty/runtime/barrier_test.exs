defmodule Monty.Runtime.BarrierTest do
  use ExUnit.Case, async: true

  alias Monty.Runtime.Barrier
  alias Monty.Test.{EchoServer, SilentServer}

  defp echo(server, request), do: fn -> GenServer.call(server, request) end

  describe "run/2" do
    test "collects replies and keeps the order the modules were listed in" do
      first = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :first))
      second = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :second))

      assert %{replies: replies, timed_out: []} =
               Barrier.run([{:lm_0, echo(first, :hello)}, {:lm_1, echo(second, :hello)}], 1_000)

      assert replies == %{lm_0: {:echo, :hello}, lm_1: {:echo, :hello}}
    end

    test "a module that does not answer inside the deadline is reported, not waited for" do
      answered = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :answered))
      silent = start_supervised!(Supervisor.child_spec({SilentServer, []}, id: :silent))

      requests = [
        {:lm_0, fn -> GenServer.call(answered, :send_out_vote, 50) end},
        {:lm_1, fn -> GenServer.call(silent, :send_out_vote, 50) end}
      ]

      assert %{replies: replies, timed_out: timed_out} = Barrier.run(requests, 50)

      assert replies == %{lm_0: {:echo, :send_out_vote}}
      assert timed_out == [:lm_1]
    end

    test "a module that has been stopped is a missing contribution" do
      server = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :gone))
      :ok = stop_supervised!(:gone)

      assert %{replies: %{}, timed_out: [:lm_0]} =
               Barrier.run([{:lm_0, echo(server, :hello)}], 1_000)
    end

    test "no modules is an empty round" do
      assert Barrier.run([], 50) == %{replies: %{}, timed_out: []}
    end
  end
end
