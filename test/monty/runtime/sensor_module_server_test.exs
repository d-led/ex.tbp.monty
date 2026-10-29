defmodule Monty.Runtime.SensorModuleServerTest do
  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.SensorModules.CameraSM
  alias Monty.Geometry.Rotation
  alias Monty.Runtime.{Registry, SensorModuleServer}

  setup do
    {:ok, model_id: "sensor-#{System.unique_integer([:positive])}"}
  end

  defp start_server(model_id, id) do
    state = CameraSM.new(id, features: ["on_object"])
    spec = %{id: id, model_id: model_id, module: CameraSM, state: state}
    start_supervised!(Supervisor.child_spec({SensorModuleServer, spec}, id: {:sensor, id}))
    Registry.via({:sensor_module, model_id, id})
  end

  defp ctx, do: Context.new(0)

  # Where the agent is, and where its sensor sits on it, as the runtime is told
  # on every step.
  defp agent_state(position \\ [0.0, 0.0, 0.0]) do
    %AgentState{
      position: position,
      rotation: Rotation.identity(),
      sensors: %{
        :patch => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
      }
    }
  end

  # One pixel, on the surface: a percept needs a point cloud to be made of
  # (`Monty.Frameworks.Models.SensorModules.ObservationProcessor`).
  defp observation do
    %{
      "location" => [0.1, 0.2, 0.3],
      "depth" => [[0.05]],
      "semantic_3d" => [[0.1, 0.2, 0.25, 1.0]]
    }
  end

  describe "step/4" do
    test "records where the sensor is, and returns the percept the module built", %{
      model_id: model_id
    } do
      server = start_server(model_id, :patch)

      percept = SensorModuleServer.step(server, observation(), agent_state(), ctx())

      assert %Monty.Cmp.Message{sender_id: "patch", pass_message: true} = percept
      assert percept.location == [0.1, 0.2, 0.25]

      assert %SensorState{position: [0.0, 0.0, 0.0]} =
               SensorModuleServer.state(server).pose
    end

    test "withholds the percept on a motor-only step", %{model_id: model_id} do
      server = start_server(model_id, :patch)

      percept = SensorModuleServer.step(server, observation(), agent_state(), ctx(), true)

      refute percept.pass_message
    end
  end

  describe "the behaviour's defaults" do
    test "a sensor that says nothing proposes no goals and attends to nothing", %{
      model_id: model_id
    } do
      server = start_server(model_id, :patch)

      assert SensorModuleServer.propose_goals(server) == []
      assert SensorModuleServer.propose_region(server) == Monty.Cmp.AttentionRegion.empty()
    end
  end

  describe "reset/1" do
    test "forgets what was seen, and keeps where the sensor is", %{model_id: model_id} do
      # Monty's `CameraSM.reset` empties the telemetry, the filter and the
      # processed observations; the sensor's place in the world has not moved
      # (`sensor_modules.py:573-577`).
      server = start_server(model_id, :patch)
      SensorModuleServer.step(server, observation(), agent_state([1.0, 0.0, 0.0]), ctx())

      assert :ok = SensorModuleServer.reset(server)

      assert SensorModuleServer.state(server).processed_observations == []
      assert %SensorState{position: [1.0, 0.0, 0.0]} = SensorModuleServer.state(server).pose
    end
  end
end
