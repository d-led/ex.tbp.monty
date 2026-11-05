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

    # The round is where a module's bug would be swallowed by the next round's
    # polite "no answer", so a raise is carried out of it with its reason.
    test "a request that raises is not swallowed as a missing answer" do
      reason = catch_exit(Barrier.run([{:lm_0, fn -> raise "a module bug" end}], 1_000))

      assert {:request_crashed, {%RuntimeError{message: "a module bug"}, _stacktrace}} = reason
    end

    # A call that gives up on its own — the request's own deadline, not the
    # round's — is a module that did not answer, not a bug in it.
    test "a request whose own call times out is a missing contribution" do
      silent = start_supervised!(Supervisor.child_spec({SilentServer, []}, id: :own_deadline))

      assert %{replies: %{}, timed_out: [:lm_0]} =
               Barrier.run([{:lm_0, fn -> GenServer.call(silent, :send_out_vote, 20) end}], 5_000)
    end

    test "no modules is an empty round" do
      assert Barrier.run([], 50) == %{replies: %{}, timed_out: []}
    end
  end

  # A round of one request with no deadline has nothing to kill and no
  # concurrency to lose, so it does not spawn: the request runs where the round
  # was called. That is the difference a test can see — the answer names the
  # process that ran it — and it is the whole reason the path exists (a spawned
  # request copies its closure, payload and all).
  describe "run/2 with one request and no deadline" do
    test "asks the module where the round was called" do
      caller = self()

      assert %{replies: %{lm_0: ^caller}, timed_out: []} =
               Barrier.run([{:lm_0, fn -> caller end}], :infinity)
    end

    test "a module that has been stopped is a missing contribution, as with a deadline" do
      server = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :gone_anyway))
      :ok = stop_supervised!(:gone_anyway)

      assert %{replies: %{}, timed_out: [:lm_0]} =
               Barrier.run([{:lm_0, echo(server, :hello)}], :infinity)
    end

    test "a request that raises is carried out of the round the same way" do
      reason = catch_exit(Barrier.run([{:lm_0, fn -> raise "a module bug" end}], :infinity))

      assert {:request_crashed, {%RuntimeError{message: "a module bug"}, _stacktrace}} = reason
    end

    test "a request whose own call times out is a missing contribution" do
      silent = start_supervised!(Supervisor.child_spec({SilentServer, []}, id: :own_deadline_any))

      assert %{replies: %{}, timed_out: [:lm_0]} =
               Barrier.run(
                 [{:lm_0, fn -> GenServer.call(silent, :send_out_vote, 20) end}],
                 :infinity
               )
    end
  end

  # Several requests still run together when there is no deadline: the round's
  # point is that they start at once, and serialising them to save a copy would
  # trade a constant for a factor of the module count.
  describe "run/2 with several requests and no deadline" do
    test "asks them all and collects the answers" do
      first = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :first_any))
      second = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :second_any))

      assert %{replies: replies, timed_out: []} =
               Barrier.run(
                 [{:lm_0, echo(first, :hello)}, {:lm_1, echo(second, :hello)}],
                 :infinity
               )

      assert replies == %{lm_0: {:echo, :hello}, lm_1: {:echo, :hello}}
    end

    test "a module that does not answer at all is the one that is missing" do
      answered = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :answered_any))
      gone = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :gone_any))
      :ok = stop_supervised!(:gone_any)

      assert %{replies: %{lm_0: {:echo, :hello}}, timed_out: [:lm_1]} =
               Barrier.run(
                 [{:lm_0, echo(answered, :hello)}, {:lm_1, echo(gone, :hello)}],
                 :infinity
               )
    end
  end
end
