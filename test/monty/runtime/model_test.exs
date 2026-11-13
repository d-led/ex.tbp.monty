defmodule Monty.Runtime.ModelTest do
  @moduledoc """
  What a model does when one of its own processes dies.

  A model is all of it or none of it. A module or the coordinator that dies takes
  the model with it, and the caller — who holds the model's name — is the one who
  finds out and can say why. A model rebuilt behind a run's back would step with a
  step count nobody reset and modules nobody fed: a run that looks alive and
  answers nothing, which is worse than a run that ends.
  """

  use ExUnit.Case, async: true

  alias Monty.Runtime.{Model, Registry}
  alias Monty.Test.{RecordingLearningModule, RecordingMotor, RecordingSensorModule}

  @agent "agent_id_0"

  test "a module that dies takes the model with it, and the model is not rebuilt" do
    model_id = "model-#{System.unique_integer([:positive])}"
    {:ok, model} = Model.start_link(spec(model_id))

    # The model is started by a caller that owns it, and a model that dies takes
    # its caller's link with it — which is the point of the change, and not what
    # this case is measuring: the monitor is.
    Process.unlink(model)
    monitor = Process.monitor(model)

    [{module_server, _value}] = Registry.lookup({:learning_module, model_id, :lm_0})
    Process.exit(module_server, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^model, :shutdown}, 1_000

    # Nothing was put back: whatever the registry still lists under this model is
    # the process that died, which is the difference between a run that can say
    # its model stopped and a run that steps something nobody rebuilt.
    assert Enum.all?(Registry.lookup({:model, model_id}), fn {pid, _value} ->
             not Process.alive?(pid)
           end)
  end

  # The failure this is for: six parts' models died together in one sweep, each was
  # a permanent child of the model supervisor, and the restarts exhausted its
  # budget until the application stopped — a clean exit that told nobody anything.
  # A model a run starts is `:temporary`, so a dead one is the run's business and
  # not the supervisor's.
  test "a model that dies leaves the model supervisor running, and is not restarted" do
    model_id = "model-#{System.unique_integer([:positive])}"
    supervisor = ExTbpMonty.Core.Supervisor.model_supervisor()

    {:ok, model} =
      DynamicSupervisor.start_child(
        supervisor,
        Supervisor.child_spec({Model, spec(model_id)}, id: model_id, restart: :temporary)
      )

    monitor = Process.monitor(model)
    Process.exit(model, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^model, :killed}, 1_000

    # A system message is answered after the exit before it, so the supervisor has
    # handled this death by the time it answers.
    _ = :sys.get_state(supervisor)

    assert Process.alive?(Process.whereis(supervisor))

    refute Enum.any?(DynamicSupervisor.which_children(supervisor), fn {_id, pid, _type, _mods} ->
             pid == model
           end)
  end

  defp spec(model_id) do
    %{
      model_id: model_id,
      sensor_modules: [
        %{
          id: :patch,
          agent_id: @agent,
          module: RecordingSensorModule,
          state: RecordingSensorModule.new(id: :patch)
        }
      ],
      learning_modules: [
        %{
          id: :lm_0,
          module: RecordingLearningModule,
          state: RecordingLearningModule.new(id: :lm_0)
        }
      ],
      sm_to_lm: %{lm_0: [:patch]},
      motor: {RecordingMotor, RecordingMotor.new()}
    }
  end
end
