# The two numbers the pose-uniqueness test turns on, step by step.
#
#   MIX_ENV=test mix run scripts/probe_pose_spread.exs [episode] [steps]
#
# `probe_episode_conclusion.exs` shows the port concluding at step 7 where
# Monty waited until 43, with the same hypothesis counts and the same evidence.
# Monty's rule is "all possible poses are within `path_similarity_threshold` of
# their centre and within `pose_similarity_threshold` of the most likely one",
# so this prints both maxima beside those two thresholds: a wide margin means
# the possible *sets* differ, a hair's breadth means the two implementations sit
# either side of a knife edge.

alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Geometry
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
    [episode] -> [String.to_integer(episode), 12]
    [] -> [1, 12]
  end

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)
percepts_per_step = MontyRecording.episodes!(recording) |> Enum.at(episode - 1)

id = "probe-spread-#{System.unique_integer([:positive])}"
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

distance = fn a, b ->
  a
  |> Enum.zip(b)
  |> Enum.map(fn {x, y} -> (x - y) * (x - y) end)
  |> Enum.sum()
  |> :math.sqrt()
end

trace = fn [[a, _b, _c], [_d, e, _f], [_g, _h, i]] -> a + e + i end

spread = fn lm, object_id ->
  hypotheses = Map.fetch!(lm.hypotheses, object_id)
  ids = EvidenceGraphLM.get_possible_hypothesis_ids(lm, object_id)

  case ids do
    [] ->
      "no possible pose"

    ids ->
      locations = Enum.map(ids, &Enum.at(hypotheses.locations, &1))
      centre = locations |> Enum.zip_with(&Monty.Math.mean/1)
      spread = locations |> Enum.map(fn location -> distance.(location, centre) end) |> Enum.max()

      mlh = EvidenceGraphLM.current_mlh(lm)
      most_likely = Rotation.to_matrix(mlh.rotation)

      turn =
        ids
        |> Enum.map(fn index ->
          pose = Enum.at(hypotheses.poses, index)
          cosine = (trace.(Geometry.mul(Geometry.transpose(most_likely), pose)) - 1) / 2
          :math.acos(Monty.Math.clip(cosine, -1.0, 1.0))
        end)
        |> Enum.max()

      "#{length(ids)} poses: spread #{Float.round(spread * 1.0, 4)}/#{lm.path_similarity_threshold}, " <>
        "turn #{Float.round(turn * 1.0, 4)}/#{lm.pose_similarity_threshold}"
  end
end

IO.puts("step | symmetry | pose spread against the two thresholds")

for step <- 0..(steps - 1) do
  {:ok, _actions, _info} = Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step})
  lm = LearningModuleServer.state(server)

  case lm.possible_matches do
    [object_id] ->
      IO.puts(
        "#{String.pad_leading("#{step}", 4)} | sym #{lm.symmetry_evidence} | #{spread.(lm, object_id)}"
      )

    others ->
      IO.puts(
        "#{String.pad_leading("#{step}", 4)} | sym #{lm.symmetry_evidence} | " <>
          "#{length(others)} objects possible"
      )
  end
end

Model.stop(id)
