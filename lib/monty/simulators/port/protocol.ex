defmodule Monty.Simulators.Port.Protocol do
  @moduledoc """
  What this port says to a simulator, and what it expects back.

  Monty's world is a Python process: MuJoCo or Habitat, driven by an action
  vocabulary (`Monty.Frameworks.Actions`) and answering observations plus
  proprioceptive state — the two payloads `MontyBase.step` is given. This
  module is that contract, in both directions, so the Elixir side can be tested
  without a simulator and a simulator can be written against it without reading
  any Elixir.

  ## Framing

  Length-prefixed JSON: a four-byte big-endian length, then that many bytes of
  UTF-8 JSON. Not newline-delimited, because a simulator that logs to stdout
  would then break the stream, and not Erlang's external term format, because
  the peer is not an Erlang node.

  The prefix is written and stripped by Erlang's `{:packet, 4}` port option, so
  this module deals in bodies only; the peer writes the same four bytes itself.

  ## Messages

  One request, one reply, both carrying an `id` so a late reply to a request
  that already timed out is recognisable rather than mistaken for this one.

      → {"id": 1, "command": "reset", "sensor_ids": ["patch"]}
      ← {"id": 1, "ok": true}

      → {"id": 2, "command": "step",
         "actions": [{"action": "move_forward", "agent_id": "agent_id_0",
                      "distance": 0.004}]}
      ← {"id": 2,
         "observations": {"agent_id_0": {"patch": {"location": [...], ...}}},
         "proprioceptive_state": {"agent_id_0": {"position": [...],
                                                "rotation": [...],
                                                "sensors": {...}}}}

      ← {"id": 2, "error": "the sensor id is not known"}

  The action maps are exactly `Monty.Frameworks.Actions.ActionJSONEncoder`'s —
  Monty's own `dict(action)` — so the peer parses what Monty's own simulator
  parses.
  """

  alias Monty.Frameworks.Actions.ActionJSONEncoder

  @type request :: {:reset, [String.t()]} | {:step, [Monty.Frameworks.Actions.Action.t()]}

  @doc """
  The body of a request, as JSON-encodable data.
  """
  @spec request(non_neg_integer(), request()) :: map()
  def request(id, {:reset, sensor_ids}),
    do: %{"id" => id, "command" => "reset", "sensor_ids" => sensor_ids}

  def request(id, {:step, actions}) do
    %{
      "id" => id,
      "command" => "step",
      "actions" => Enum.map(actions, &ActionJSONEncoder.encode/1)
    }
  end

  @doc """
  What a reply means.

  A reply that is not JSON, or that answers a different request, is reported
  rather than guessed at: a simulator that has drifted from this contract is a
  bug to fix, not a case to handle.
  """
  @spec reply(binary(), non_neg_integer()) ::
          {:ok, map(), map()} | {:error, term()}
  def reply(body, id) do
    case Jason.decode(body) do
      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:simulator_error, error}}

      {:ok, %{"id" => ^id, "observations" => observations, "proprioceptive_state" => state}} ->
        {:ok, observations, state}

      {:ok, %{"id" => ^id, "ok" => true}} ->
        {:ok, %{}, %{}}

      {:ok, %{"id" => other}} when other != id ->
        {:error, {:wrong_reply, %{expected: id, got: other}}}

      {:ok, other} ->
        {:error, {:unexpected_reply, other}}

      {:error, reason} ->
        {:error, {:not_json, reason}}
    end
  end
end
