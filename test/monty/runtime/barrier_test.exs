defmodule Monty.Runtime.BarrierTest do
  use ExUnit.Case, async: true

  alias Monty.Runtime.Barrier
  alias Monty.Test.{EchoServer, SilentServer}

  describe "call/3" do
    test "collects replies and keeps the order the modules were listed in" do
      first = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :first))
      second = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :second))

      assert %{replies: replies, timed_out: []} =
               Barrier.call([{:lm_0, first}, {:lm_1, second}], :hello, 1_000)

      assert replies == %{lm_0: {:echo, :hello}, lm_1: {:echo, :hello}}
    end

    test "a module that does not answer inside the deadline is reported, not waited for" do
      answered = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :answered))
      silent = start_supervised!(Supervisor.child_spec({SilentServer, []}, id: :silent))

      assert %{replies: replies, timed_out: timed_out} =
               Barrier.call([{:lm_0, answered}, {:lm_1, silent}], :send_out_vote, 50)

      assert replies == %{lm_0: {:echo, :send_out_vote}}
      assert timed_out == [:lm_1]
    end

    test "no modules is an empty round" do
      assert Barrier.call([], :anything, 50) == %{replies: %{}, timed_out: []}
    end
  end

  describe "call_each/2" do
    test "asks each module its own question" do
      first = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :first))
      second = start_supervised!(Supervisor.child_spec({EchoServer, []}, id: :second))

      assert %{replies: replies} =
               Barrier.call_each([{:lm_0, first, :one}, {:lm_1, second, :two}], 1_000)

      assert replies == %{lm_0: {:echo, :one}, lm_1: {:echo, :two}}
    end
  end
end
