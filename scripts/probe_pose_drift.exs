# Does the port aim at the pose Monty aimed at?
#
#   MIX_ENV=test mix run scripts/probe_pose_drift.exs [episode] [steps]
#
# Evidence agrees with Monty's to about 2e-4 relative, which is enough to put two
# poses either side of the 20%-of-best cutoff in the dice episode. Before blaming
# the arithmetic, this checks the thing underneath it: the most likely hypothesis
# — which one, and how far its rotation is from Monty's own. A drift here means
# the poses disagree and the evidence is a consequence; agreement to rounding
# means the poses are the same and the difference is in summing the features.

alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Geometry.Rotation
alias Monty.Runtime.{LearningModuleServer, Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"

[episode, steps] =
  case System.argv() do
    [episode, steps] -> [String.to_integer(episode), String.to_integer(steps)]
    [episode] -> [String.to_integer(episode), 40]
    [] -> [7, 40]
  end

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)

episodes = MontyRecording.episodes!(recording)
percepts_per_step = Enum.at(episodes, episode - 1)
monty_offset = episodes |> Enum.take(episode - 1) |> Enum.map(&length/1) |> Enum.sum()
monty = MontyRecording.mlh!(recording)

id = "probe-drift-#{System.unique_integer([:positive])}"
spec = Setup.model_spec(opened.setup, id)
module_id = hd(spec.learning_modules).id

spec =
  spec
  |> Map.merge(%{
    sensor_modules: [
      %{
        id: "patch",
        agent_id: Environment.agent_id(),
        module: Recording.SensorModule,
        state:
          Recording.SensorModule.new(
            "patch",
            Enum.map(percepts_per_step, fn
              [] -> nil
              [percept | _rest] -> percept
            end)
          )
      }
    ],
    sm_to_lm: %{module_id => ["patch"]},
    lm_to_lm_vote: %{module_id => []}
  })
  |> Map.drop([:motor])

{:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})
:ok = Model.set_experiment_mode(id, :eval)
server = Registry.via({:learning_module, id, module_id})

# The angle between two orientations, in radians, from their quaternions. Monty
# writes them `wxyz` and the port `xyzw`, so both are read as `wxyz` here.
turn = fn {w1, x1, y1, z1}, [w2, x2, y2, z2] ->
  dot = abs(x1 * x2 + y1 * y2 + z1 * z2 + w1 * w2)
  2 * :math.acos(Monty.Math.clip(dot, 0.0, 1.0))
end

IO.puts("step | port: pose id, graph | Monty: pose id, graph | rotation apart (rad)")

for step <- 0..(steps - 1) do
  {:ok, _actions, _info} = Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step})
  lm = LearningModuleServer.state(server)
  ours = EvidenceGraphLM.current_mlh(lm)
  theirs = Enum.at(monty, monty_offset + step) || %{id: nil, graph_id: nil, rotation: nil}

  apart =
    cond do
      is_nil(ours) or is_nil(theirs[:rotation]) or is_nil(ours.mlh_id) ->
        "—"

      true ->
        [x, y, z, w] = Rotation.to_xyzw(ours.rotation)
        Float.round(turn.({w, x, y, z}, theirs.rotation) * 1.0, 12)
    end

  IO.puts(
    "#{String.pad_leading("#{step}", 4)} | " <>
      "#{String.pad_trailing("#{inspect(ours && ours.mlh_id)}, #{inspect(ours && ours.graph_id)}", 24)} | " <>
      "#{String.pad_trailing("#{inspect(theirs.id)}, #{inspect(theirs.graph_id)}", 24)} | #{apart}"
  )
end

Model.stop(id)
