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
  agent position in the global frame.
  """
  @spec observations(non_neg_integer()) :: {map(), map()}
  def observations(step) do
    x = step * 0.01

    observations = %{
      @agent_id => %{
        @sensor_id => %{
          "location" => [x, 0.0, 0.1],
          "value" => x
        }
      }
    }

    proprioceptive_state = %{
      @agent_id => %{
        "position" => [x, 0.0, 0.0],
        "rotation" => [1.0, 0.0, 0.0, 0.0],
        "sensors" => %{
          @sensor_id => %{"position" => [0.0, 0.0, 0.1], "rotation" => [1.0, 0.0, 0.0, 0.0]}
        }
      }
    }

    {observations, proprioceptive_state}
  end

  @doc "How the runtime addresses this environment's parts in a module spec."
  @spec agent_id() :: String.t()
  def agent_id, do: @agent_id
end
