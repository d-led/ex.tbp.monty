# Is our percept Monty's percept? Give our world his actions and read it.
#
#   MIX_ENV=test mix run --no-start scripts/probe_percept_parity.exs [experiment]
#
# `test/fixtures/monty_base_10simobj_episode.jsonl` is a recording of Monty's own
# run: every step's actions, and every percept his learning module was given. A
# step's actions are answered by the next step's observations, so the percept of
# the first step that has one is what the actions before it produce. Replaying
# those actions in our world and reading that percept says whether the world, the
# camera and the feature maths are his — which is the question a read rate hangs
# on, because a percept that differs is a percept his filter decides differently.
#
# It needs Monty's YCB meshes (`$MONTY_DATA/mujoco/objects/ycb`), an OpenGL
# context and the interpreter this application carries, so it is a probe and not
# a test: a CI machine has no display to render into.

defmodule PerceptParity do
  @moduledoc false

  alias Monty.Frameworks.Actions.{MoveForward, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Studio
  alias Monty.Studio.Setup

  def main do
    experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"
    steps = read(fixture())
    first_read = Enum.find_index(steps, &(percepts(&1) != []))
    actions = steps |> Enum.take(first_read) |> Enum.flat_map(& &1["actions"])

    IO.puts("#{first_read} of Monty's actions, then the percept they produce")

    ours = replay(experiment, actions) |> read_patch()
    theirs = steps |> Enum.at(first_read) |> percepts() |> hd() |> comparison()

    report("centre hsv", ours.centre_hsv, theirs.centre_hsv)
    report("min_depth", ours.min_depth, theirs.min_depth)
    report("mean_depth", ours.mean_depth, theirs.mean_depth)

    if ours == theirs do
      IO.puts("\nthe percept is Monty's, to the last bit")
    else
      IO.puts("\nthe percept differs — the world, not the model, is where it starts")
      System.halt(1)
    end
  end

  defp fixture, do: Path.join(__DIR__, "../test/fixtures/monty_base_10simobj_episode.jsonl")

  defp read(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp percepts(step), do: step["learning_modules"]["learning_module_0"]["inputs"]

  # One episode's first steps in our own world, given Monty's actions.
  defp replay(experiment, actions) do
    agent_id = Monty.Simulators.Synthetic.Environment.agent_id()

    # The Python world is a GenServer over an embedded interpreter, and a probe
    # runs with `--no-start`, so the two pieces it needs are started here.
    {:ok, _python} = Application.ensure_all_started(:pythonx)
    {:ok, _host} = Monty.Simulators.Mujoco.Host.start_link([])

    {:ok, opened} = Studio.open(experiment, world_simulator: :mujoco)
    world = opened.setup |> Setup.world(:mujoco, 0) |> then(& &1.__struct__.reset(&1))

    {observations, _world} =
      actions
      |> Enum.map(&action(&1, agent_id))
      |> Enum.reduce({nil, world}, fn action, {_last, world} ->
        {observations, _state, world} = world.__struct__.step(world, [action])
        {observations, world}
      end)

    observations[agent_id]["patch"]
  end

  # Monty's action as the struct this port steps a world with, parameters and all.
  defp action(%{"action" => "move_forward"} = recorded, agent_id),
    do: %MoveForward{agent_id: agent_id, distance: recorded["distance"]}

  defp action(%{"action" => "orient_horizontal"} = recorded, agent_id),
    do: %OrientHorizontal{
      agent_id: agent_id,
      rotation_degrees: recorded["rotation_degrees"],
      left_distance: recorded["left_distance"],
      forward_distance: recorded["forward_distance"]
    }

  defp action(%{"action" => "orient_vertical"} = recorded, agent_id),
    do: %OrientVertical{
      agent_id: agent_id,
      rotation_degrees: recorded["rotation_degrees"],
      down_distance: recorded["down_distance"],
      forward_distance: recorded["forward_distance"]
    }

  # A patch as the three numbers a percept is compared on: the middle pixel's
  # colour, and the two ends of the depths that met the object.
  defp read_patch(patch) do
    rows = patch["rgba"]
    middle = rows |> length() |> div(2) |> then(&Enum.at(rows, &1))
    [red, green, blue, _alpha] = middle |> length() |> div(2) |> then(&Enum.at(middle, &1))

    depths = patch["depth"] |> List.flatten() |> Enum.reject(&(&1 == 0.0))

    %{
      centre_hsv: SensorProcessing.rgb2hsv([red, green, blue]),
      min_depth: Enum.min(depths),
      mean_depth: Enum.sum(depths) / length(depths)
    }
  end

  defp comparison(percept) do
    features = percept["non_morphological_features"]

    %{
      centre_hsv: features["hsv"],
      min_depth: features["min_depth"],
      mean_depth: features["mean_depth"]
    }
  end

  defp report(label, ours, theirs) do
    verdict = if ours == theirs, do: "the same", else: "differs"
    IO.puts("#{String.pad_trailing(label, 12)} #{verdict}")
    IO.puts("  ours:   #{inspect(ours)}")
    IO.puts("  theirs: #{inspect(theirs)}")
  end
end

PerceptParity.main()
