defmodule Monty.Studio.RunPrologueTest do
  @moduledoc """
  An episode starts the way Monty starts one.

  Monty's `Interface.pre_episode/1` is where an episode begins: the world is
  asked for one, and only then is the model told what it is about — in that order,
  because the second answer comes from the world the first one reset.

  The stand-in scene is the instrument: it is a value, so a run of it needs no
  process, no interpreter and no mesh. A MuJoCo run is the same prologue with a
  world that names an object, and that half is specified beside the world it
  belongs to (`Monty.Simulators.Mujoco.Environment`).
  """

  use ExUnit.Case, async: false

  alias Monty.Experiment.Environment.Interface
  alias Monty.Runtime.{LearningModuleServer, Registry}
  alias Monty.Studio.Run

  setup do
    {:ok, opened} = Monty.Studio.open("base_10simobj_surf_agent", world_simulator: :synthetic)
    {:ok, run} = Run.start(opened.setup, steps: 1)
    on_exit(fn -> Run.stop(run) end)

    {:ok, setup: opened.setup, run: run}
  end

  test "a run steps the world its pre-episode reset answered", %{run: run} do
    # `Interface.pre_episode/1` answers the interface holding the world's reset,
    # and positioning ran on that one: a run that had skipped it would be stepping
    # a world nobody had told an episode had begun.
    assert %Interface{env: %Monty.Simulators.Synthetic.Environment{}} = run.interface
    assert is_map(run.positioning)
  end

  test "and a world that names no object leaves the model without a target", %{
    setup: setup,
    run: run
  } do
    # Monty's `MontyObjectRecognitionExperiment.pre_episode` carries the world's
    # answer to the model. This world answers nothing — one sphere, and no object
    # — so the model is told nothing rather than told a guess.
    assert :ok = Run.set_ground_truth(run)

    [lm | _rest] = setup.learning_modules
    state = LearningModuleServer.state(Registry.via({:learning_module, run.model_id, lm.id}))

    assert state.primary_target == nil
  end
end
