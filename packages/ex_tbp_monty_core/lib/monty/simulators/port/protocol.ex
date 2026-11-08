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
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.Rotation

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

  The fourth element is what the world said about the episode, which only a reset
  answer has: `%{"primary_target" => target}` and the scene's
  `"semantic_id_to_label"`. It is a map rather than an option so a world that says
  nothing costs nobody a clause, and one that has more to say one day does not
  need a new arity.
  """
  @spec reply(binary(), non_neg_integer()) ::
          {:ok, map(), map(), map()} | {:error, term()}
  def reply(body, id) do
    case Jason.decode(body) do
      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:simulator_error, error}}

      {:ok,
       %{"id" => ^id, "observations" => observations, "proprioceptive_state" => state} = reply} ->
        {:ok, observations, state, episode(reply)}

      {:ok, %{"id" => ^id, "ok" => true} = reply} ->
        {:ok, %{}, %{}, episode(reply)}

      {:ok, %{"id" => other}} when other != id ->
        {:error, {:wrong_reply, %{expected: id, got: other}}}

      {:ok, other} ->
        {:error, {:unexpected_reply, other}}

      {:error, reason} ->
        {:error, {:not_json, reason}}
    end
  end

  # What a world can say about an episode. A key it leaves out is a world that
  # has no answer for it, which is not the same as an empty answer.
  @episode_keys ["primary_target", "semantic_id_to_label"]

  defp episode(reply) do
    reply
    |> Map.take(@episode_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Proprioceptive state, as the port works with it.

  A reply carries Monty's own shape — per agent its `position`, its `rotation` as
  a **`wxyz`** quaternion, and its sensors the same way — while the motor system
  works in `AgentState` and `SensorState`. The order is Monty's, not JSON's:
  `quaternion.quaternion` writes `wxyz` and the port's own quaternions are
  `xyzw`, so it is named here rather than guessed at by a caller.

  A reply that leaves a position or a rotation out is a simulator that has
  drifted from this contract, and says so with the agent it happened for.
  """
  @spec proprioceptive_state(map()) :: Monty.Frameworks.Models.MotorSystemState.t()
  def proprioceptive_state(agents) when is_map(agents) do
    Map.new(agents, fn {agent_id, agent} -> {agent_id, agent_state(agent)} end)
  end

  defp agent_state(%{"position" => position, "rotation" => rotation} = agent) do
    %AgentState{
      position: position,
      rotation: rotation_of(rotation),
      sensors:
        Map.new(Map.get(agent, "sensors", %{}), fn {sensor_id, sensor} ->
          {sensor_id, sensor_state(sensor)}
        end)
    }
  end

  defp agent_state(other) do
    raise ArgumentError,
          "a simulator's agent state needs a position and a rotation, got: #{inspect(other)}"
  end

  defp sensor_state(%{"position" => position, "rotation" => rotation}) do
    %SensorState{position: position, rotation: rotation_of(rotation)}
  end

  # A zero quaternion is not an orientation, so a simulator that sends one is
  # reported rather than given the identity by default.
  defp rotation_of([_, _, _, _] = quaternion) do
    case Rotation.from_quaternion(List.to_tuple(quaternion)) do
      {:ok, rotation} ->
        rotation

      {:error, reason} ->
        raise ArgumentError, "a simulator's rotation is not one: #{inspect(reason)}"
    end
  end

  defp rotation_of(other) do
    raise ArgumentError, "a simulator's rotation is `wxyz`, got: #{inspect(other)}"
  end
end
