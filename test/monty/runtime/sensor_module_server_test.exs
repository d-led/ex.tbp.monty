defmodule Monty.Runtime.SensorModuleServerTest do
  use ExUnit.Case, async: true

  alias Monty.Runtime.{Registry, SensorModuleServer}
  alias Monty.Simulators.Synthetic.SensorModule

  setup do
    {:ok, model_id: "sensor-#{System.unique_integer([:positive])}"}
  end

  defp start_server(model_id, id) do
    state = SensorModule.new(id, features: ["on_object"])
    spec = %{id: id, model_id: model_id, module: SensorModule, state: state}
    start_supervised!(Supervisor.child_spec({SensorModuleServer, spec}, id: {:sensor, id}))
    Registry.via({:sensor_module, model_id, id})
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
    test "records the agent state and returns the percept the module built", %{model_id: model_id} do
      server = start_server(model_id, :patch)
      agent_state = %{"position" => [0.0, 0.0, 0.0]}

      percept = SensorModuleServer.step(server, observation(), agent_state)

      assert %Monty.Cmp.Message{sender_id: "patch", pass_message: true} = percept
      assert percept.location == [0.1, 0.2, 0.25]
      assert SensorModuleServer.state(server).pose == agent_state
    end

    test "withholds the percept on a motor-only step", %{model_id: model_id} do
      server = start_server(model_id, :patch)

      percept = SensorModuleServer.step(server, observation(), %{}, true)

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
    test "clears the recorded pose", %{model_id: model_id} do
      server = start_server(model_id, :patch)

      SensorModuleServer.step(server, observation(), %{"position" => [1.0, 0.0, 0.0]})

      assert :ok = SensorModuleServer.reset(server)
      assert SensorModuleServer.state(server).pose == nil
    end
  end
end
