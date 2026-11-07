defmodule Monty.Frameworks.Experiments.PretrainingExperiments.MontySupervisedObjectPretrainingExperimentTest do
  @moduledoc """
  The tutorial experiment's own class, stepped against Monty's world.

  Monty has no unit test for `pretraining_experiments.py`; its referee is
  `tests/integration/frameworks/experiments/graph_building_test.py`, which needs
  Habitat-Sim and is skipped without it. These cases state what this port means
  by the class, and the second one is the whole point of it: an episode that was
  told what it saw leaves a graph named after the object.

  The run is started here rather than by the class, because that is how both
  runners do it — `pre_episode` adds what an episode of *this* experiment begins
  with, and the world is already in front of the agent.
  """

  use ExUnit.Case, async: false

  # The tutorial's scene is a YCB object, and the meshes are a prerequisite this
  # suite does not carry (`host_test.exs` says the same about a scene with
  # objects). A machine with `MONTY_DATA` unpacked runs these; a machine without
  # skips them, and says so rather than failing on a mesh that is not there.
  @ycb "ycb_objects_1_0"

  @moduletag skip:
               if(Monty.Prerequisites.present?(Monty.Prerequisites.get(@ycb)),
                 do: false,
                 else: "the YCB meshes (#{@ycb}) are not on this machine"
               )

  alias Monty.Frameworks.Experiments.PretrainingExperiments.MontySupervisedObjectPretrainingExperiment,
    as: Pretraining

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Runtime.Model
  alias Monty.Studio.Run

  @experiment "tutorial/first_experiment"
  @learning_module "learning_module_0"
  @input_channel "patch"

  # What a runner gives an experiment class: the two hooks it may call, and
  # nothing at either end that the class has to do.
  defp callbacks do
    %{
      pre_episode: fn state, _index, _object, _callbacks -> {:ok, state} end,
      ground_truth: &Run.set_ground_truth/1,
      post_episode: fn state, _outcome, _infos -> state end
    }
  end

  defp start(options \\ []) do
    # MuJoCo, because a supervised episode reads the object and pose it was
    # given off the world: the stand-in scene has no target to state.
    {:ok, opened} = Monty.Studio.open(@experiment, world_simulator: :mujoco)

    {:ok, run} = Run.start(opened.setup, Keyword.merge([steps: 3, mode: :train], options))
    on_exit(fn -> Run.stop(run) end)
    run
  end

  defp step_through(run, 0), do: run

  defp step_through(run, steps) do
    {:ok, _info, _observations, next} = Run.step(run)
    step_through(next, steps - 1)
  end

  # What the module was told, read out of the process that holds it. The
  # tutorial's module composes a graph module, and the statistics are the graph
  # module's — which is where a matching episode would have written them too.
  defp learning_module_stats(run) do
    %{learning_modules: [only]} = Model.detailed(run.model_id, & &1.graph_lm.buffer.stats)
    only.state
  end

  test "an episode whose modules are all supervised explores instead of matching" do
    run = start()

    {:ok, state} = Pretraining.pre_episode(%{run: run}, 0, "mug", callbacks())

    assert Model.state(state.run.model_id).step_type == :exploratory
  end

  test "an object first seen elsewhere keeps the place its graph was learned at" do
    # Monty's `first_epoch_object_location`: the answer is "here on the model",
    # and a later epoch that puts the object somewhere else must still extend
    # the graph it built the first time.
    run = start(first_seen: %{"mug" => [0.4, 1.5, 0.0]})

    {:ok, supervised} = Run.supervise(run)

    assert supervised.first_seen["mug"] == [0.4, 1.5, 0.0]

    stats = learning_module_stats(supervised)
    assert stats["detected_location_on_model"] == [0.4, 1.5, 0.0]
    assert stats["detected_location_rel_body"] == [0.0, 1.5, 0.0]
  end

  test "an episode that crashed is told nothing, so a dead model cannot fail it twice" do
    # A crash took the model with it. Asking it for the answer would replace the
    # reason the run ended with "a process the run was waiting on exited".
    run = start()
    :ok = Model.stop(run.model_id)

    state = Pretraining.post_episode(%{run: run}, {:crashed, 2, :boom}, [], callbacks())

    assert state.run == run
  end

  test "the episode's answer becomes a graph named after the object" do
    run = start()
    {:ok, state} = Pretraining.pre_episode(%{run: run}, 0, "mug", callbacks())

    run = step_through(state.run, 3)
    state = Pretraining.post_episode(%{run: run}, :finished, [], callbacks())

    learned = Run.next_memories(state.run, %{}, :train)
    memory = Map.fetch!(learned, @learning_module)

    assert GraphMemory.get_memory_ids(memory) == ["mug"]

    nodes = GraphMemory.get_graph_node_ids(memory, "mug", @input_channel)
    assert nodes != []
  end
end
