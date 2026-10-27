defmodule Monty.Runtime.Barrier do
  @moduledoc """
  One phase of a step: ask every module the same kind of question, and wait.

  Monty's step is a sequence of barriers — all percepts, then all learning
  module steps, then all votes — so the barrier is the unit of concurrency
  here. `Task.async_stream/3` gives the two properties a step needs:

    * **order** — results come back in the order the modules were listed, so a
      seeded run does not depend on which reply arrived first;
    * **deadlines** — a finite timeout kills only the task that is late, which
      is what makes an opportunistic vote round possible: the replies that
      arrived are kept, the stragglers are reported.

  `:infinity` reproduces Monty's synchronous round exactly.
  """

  @type id :: atom() | String.t()
  @type reply :: {id(), term()}
  @type result :: %{replies: %{optional(id()) => term()}, timed_out: [id()]}

  @doc """
  Asks the same request of every server. `servers` is a list of
  `{id, server}` where `server` is a pid or a `:via` tuple.
  """
  @spec call([{id(), GenServer.server()}], term(), timeout()) :: result()
  def call(servers, request, timeout) do
    call_each(Enum.map(servers, fn {id, server} -> {id, server, request} end), timeout)
  end

  @doc "Asks each server its own request, still in the given order."
  @spec call_each([{id(), GenServer.server(), term()}], timeout()) :: result()
  def call_each([], _timeout), do: %{replies: %{}, timed_out: []}

  def call_each(requests, timeout) do
    requests
    |> Task.async_stream(
      fn {id, server, request} -> {id, GenServer.call(server, request, timeout)} end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: length(requests)
    )
    |> Enum.zip(requests)
    |> Enum.reduce(%{replies: %{}, timed_out: []}, fn
      {{:ok, {id, reply}}, _request}, acc -> %{acc | replies: Map.put(acc.replies, id, reply)}
      {{:exit, _reason}, {id, _server, _request}}, acc -> %{acc | timed_out: [id | acc.timed_out]}
    end)
    |> then(fn acc -> %{acc | timed_out: Enum.reverse(acc.timed_out)} end)
  end
end
