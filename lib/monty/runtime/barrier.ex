defmodule Monty.Runtime.Barrier do
  @moduledoc """
  One phase of a step: ask every module the same kind of question, and wait.

  Monty's step is a sequence of barriers — all percepts, then all learning
  module steps, then all votes — so the barrier is the unit of concurrency
  here. Callers pass a list of `{id, fun}` pairs, where `fun` makes *one* call
  through a module server's public API; the barrier does not know about
  GenServers, mailboxes or payload shapes.

  `Task.async_stream/3` gives the two properties a step needs:

    * **order** — results come back in the order the modules were listed, so a
      seeded run does not depend on which reply arrived first;
    * **deadlines** — a finite timeout kills only the task that is late, which
      is what makes an opportunistic vote round possible: the replies that
      arrived are kept, the stragglers are reported.

  `:infinity` reproduces Monty's synchronous round exactly.
  """

  @type id :: atom() | String.t()
  @type request :: {id(), (-> term())}
  @type result :: %{replies: %{optional(id()) => term()}, timed_out: [id()]}

  @doc """
  Runs each request, in the given order.

  A module that is unavailable — no process under its name, or one that is
  shutting down — is reported as timed out rather than taking the round with
  it, and a request that runs past the deadline is killed the same way. A
  request that raises is not swallowed: the tasks are linked, the round
  crashes, and the model's supervisor restarts it with the stack trace intact.
  """
  @spec run([request()], timeout()) :: result()
  def run([], _timeout), do: %{replies: %{}, timed_out: []}

  def run(requests, timeout) do
    requests
    |> Task.async_stream(
      fn {id, request} -> {id, call(request)} end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: length(requests)
    )
    |> Enum.zip(requests)
    |> Enum.reduce(%{replies: %{}, timed_out: []}, fn
      {{:ok, {id, :unavailable}}, _request}, result ->
        %{result | timed_out: [id | result.timed_out]}

      {{:ok, {id, reply}}, _request}, result ->
        %{result | replies: Map.put(result.replies, id, reply)}

      {{:exit, _reason}, {id, _request}}, result ->
        %{result | timed_out: [id | result.timed_out]}
    end)
    |> Map.update!(:timed_out, &Enum.reverse/1)
  end

  # Only "there is no process to answer" is turned into a missing
  # contribution. Anything else — an exception, a bad match, a timeout raised
  # by a caller that set its own — is a bug or a decision, and stays visible.
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
