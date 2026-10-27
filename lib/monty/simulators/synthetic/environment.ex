defmodule Monty.Simulators.Synthetic.Environment do
  @moduledoc """
  A stand-in environment for developing the runtime.

  Monty's 3D world is an external process (MuJoCo behind a port, later). Until
  that bridge exists, the runtime needs something deterministic to step: this
  module moves a single agent along +x by one centimetre per step and returns
  the two payloads Monty's `Interface.step/1` returns — observations per agent
  and sensor, and the proprioceptive state in global coordinates.

  It is a simulator, not a ported module: nothing here claims to mirror a
  Python file.
  """

  @agent_id "agent_id_0"
  @sensor_id "patch"

  @doc """
  Observations and proprioceptive state for a step.

  Keys and units follow Monty: metres, sensor position relative to the agent,
  agent position in the global frame. Every sensor the caller names sees the
  same moving scene from its own offset, so an experiment with several sensors
  gets several percepts per step — which is what its wiring expects.
  """
  @spec observations(non_neg_integer(), [String.t()]) :: {map(), map()}
  def observations(step, sensor_ids \\ [@sensor_id]) do
    sensor_ids = if sensor_ids == [], do: [@sensor_id], else: sensor_ids
    x = step * 0.01

    observations = %{
      @agent_id =>
        Map.new(Enum.with_index(sensor_ids), fn {sensor_id, index} ->
          {sensor_id, %{"location" => [x, 0.0, 0.1 + index * 0.01], "value" => x}}
        end)
    }

    proprioceptive_state = %{
      @agent_id => %{
        "position" => [x, 0.0, 0.0],
        "rotation" => [1.0, 0.0, 0.0, 0.0],
        "sensors" =>
          Map.new(Enum.with_index(sensor_ids), fn {sensor_id, index} ->
            {sensor_id,
             %{
               "position" => [0.0, 0.0, 0.1 + index * 0.01],
               "rotation" => [1.0, 0.0, 0.0, 0.0]
             }}
          end)
      }
    }

    {observations, proprioceptive_state}
  end

  @doc "How the runtime addresses this environment's parts in a module spec."
  @spec agent_id() :: String.t()
  def agent_id, do: @agent_id
end
