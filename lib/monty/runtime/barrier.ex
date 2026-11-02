defmodule Monty.Runtime.Barrier do
  @moduledoc """
  One phase of a step: ask every module the same kind of question, and wait.

  Monty's step is a sequence of barriers — all percepts, then all learning
  module steps, then all votes — so the barrier is the unit of concurrency
  here. Callers pass a list of `{id, fun}` pairs, where `fun` makes *one* call
  through a module server's public API; the barrier does not know about
  GenServers, mailboxes or payload shapes.

  Every request starts before any of them is awaited, so a module that is slow
  does not hold up the modules behind it — that is Monty's round. Replies come
  back keyed by id, and a request that misses its deadline is reported rather
  than waited for, which is what makes an opportunistic vote round possible.

  Each request runs in a process of its own, because a deadline needs one: a
  call that will not come back has to be killed, and only its own process can
  be. That process is the whole mechanism — spawned, monitored, and then its
  reply or its death is received. `Task.async_stream/3` does the same work
  through a stream, a monitor per element and a `:kill_task` path, and measured
  against it on this machine (paired, step by step, both under the same load)
  the round below is the cheaper of the two; a step is four rounds and a run is
  thousands of steps, so the round is worth keeping small.
  """

  @type id :: atom() | String.t()
  @type request :: {id(), (-> term())}
  @type result :: %{replies: %{optional(id()) => term()}, timed_out: [id()]}

  @doc """
  Runs each request, all of them at once, and collects the answers.

  A module that is unavailable — no process under its name, or one that is
  shutting down — is reported as timed out rather than taking the round with
  it, and a request that runs past the deadline is killed the same way. A
  request that raises is not swallowed: the round exits with the request's
  reason, so a bug in a module is a bug and not a module that answered nothing.
  """
  @spec run([request()], timeout()) :: result()
  def run([], _timeout), do: %{replies: %{}, timed_out: []}

  def run(requests, timeout) do
    started = Enum.map(requests, fn {id, request} -> {id, start(request, timeout)} end)

    started
    |> Enum.reduce(%{replies: %{}, timed_out: []}, fn {id, worker}, result ->
      case await(worker) do
        {:answered, :unavailable} -> %{result | timed_out: [id | result.timed_out]}
        {:answered, reply} -> %{result | replies: Map.put(result.replies, id, reply)}
        :missing -> %{result | timed_out: [id | result.timed_out]}
      end
    end)
    |> Map.update!(:timed_out, &Enum.reverse/1)
  end

  defp start(request, timeout) do
    parent = self()
    reference = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {reference, call(request)}) end)

    %{pid: pid, monitor: monitor, reference: reference, deadline: deadline(timeout)}
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp await(%{pid: pid, monitor: monitor, reference: reference, deadline: deadline}) do
    receive do
      {^reference, reply} ->
        Process.demonitor(monitor, [:flush])
        {:answered, reply}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        missing_or_crashed(reason)
    after
      remaining(deadline) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :missing
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A request that ran out of its own time, or whose module went away, is a
  # missing contribution. Anything else is the request itself failing, and a
  # round that turned that into "no answer" would hide the bug.
  defp missing_or_crashed(reason) when reason in [:normal, :shutdown, :noproc], do: :missing
  defp missing_or_crashed({:shutdown, _details}), do: :missing
  defp missing_or_crashed({:timeout, _details}), do: :missing
  defp missing_or_crashed({:noproc, _details}), do: :missing
  defp missing_or_crashed(reason), do: exit({:request_crashed, reason})

  # Only "there is no process to answer" is turned into a missing contribution.
  # Anything else is a decision of the request's own, and is reported by its
  # exit reason.
  defp call(request) do
    request.()
  catch
    :exit, :noproc -> :unavailable
    :exit, {:noproc, _details} -> :unavailable
    :exit, :normal -> :unavailable
    :exit, {:normal, _details} -> :unavailable
    :exit, :shutdown -> :unavailable
    :exit, {:shutdown, _details} -> :unavailable
  end
end
