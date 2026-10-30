# The numbers an episode's ending turns on, Monty's beside the port's.
#
#   MIX_ENV=test mix run scripts/probe_episode_conclusion.exs [episode] [steps]
#
# An episode ends when one object is left *and* its pose is narrow enough to
# name, or when the same alternatives have survived `required_symmetry_evidence`
# steps. `probe_dist_agent_episodes.exs` reports which episodes the port ends the
# way Monty did; this prints the two quantities that decide it — the symmetry
# count, and the two maxima of the pose test against their thresholds — so an
# episode that ends early, late or not at all can be attributed to one of them.

alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
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
    [episode] -> [String.to_integer(episode), 50]
    [] -> [1, 50]
  end

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)

percepts_per_step = MontyRecording.episodes!(recording) |> Enum.at(episode - 1)
monty_conditions = MontyRecording.terminal_conditions!(recording)
monty_evidence = MontyRecording.graph_evidence!(recording)

# Monty's rows run episode after episode, so this episode's start is found by
# the episode number rather than assumed to be the first.
episodes = MontyRecording.episodes!(recording)
monty_offset = episodes |> Enum.take(episode - 1) |> Enum.map(&length/1) |> Enum.sum()

id = "probe-conclusion-#{System.unique_integer([:positive])}"
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

# The same two numbers the terminal condition compares, computed from what the
# module holds after the step.
spread = fn lm, object_id ->
  hypotheses = Map.fetch!(lm.hypotheses, object_id)
  ids = EvidenceGraphLM.get_possible_hypothesis_ids(lm, object_id)

  case ids do
    [] ->
      "no possible pose"

    ids ->
      locations = Enum.map(ids, &Enum.at(hypotheses.locations, &1))
      centre = locations |> Enum.zip_with(&Monty.Math.mean/1)
      apart = locations |> Enum.map(fn location -> distance.(location, centre) end) |> Enum.max()

      most_likely = Rotation.to_matrix(EvidenceGraphLM.current_mlh(lm).rotation)

      turn =
        ids
        |> Enum.map(fn index ->
          pose = Enum.at(hypotheses.poses, index)
          cosine = (trace.(Geometry.mul(Geometry.transpose(most_likely), pose)) - 1) / 2
          :math.acos(Monty.Math.clip(cosine, -1.0, 1.0))
        end)
        |> Enum.max()

      "#{length(ids)} poses, spread #{Float.round(apart * 1.0, 4)}, turn #{Float.round(turn * 1.0, 4)}"
  end
end

monty = fn step ->
  case Enum.at(monty_conditions, monty_offset + step) do
    nil ->
      "—"

    conditions ->
      "#{conditions.poses} poses, spread #{Float.round(conditions.spread * 1.0, 4)}, " <>
        "turn #{Float.round(conditions.turn * 1.0, 4)}, " <>
        "unique #{conditions.unique}, sym #{conditions.symmetry}"
  end
end

monty_space = fn we ->
  we = we || %{}

  leading =
    we
    |> Enum.reject(fn {_id, graph} -> graph["max_evidence"] == 0 end)
    |> Enum.max_by(fn {_id, graph} -> graph["max_evidence"] end, fn -> {nil, nil} end)

  case leading do
    {nil, nil} ->
      "—"

    {_id, graph} ->
      "#{graph["hypotheses"]} of them, top " <>
        "#{inspect(Enum.map(graph["top_evidence"], &Float.round(&1 * 1.0, 2)))}"
  end
end

IO.puts("step | port: symmetry, terminal, pose test, space         | Monty")

for step <- 0..(steps - 1) do
  {:ok, _actions, _info} = Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step})
  lm = LearningModuleServer.state(server)

  {ids, evidences} = EvidenceGraphLM.evidence_for_each_graph(lm)

  counted =
    Enum.zip(ids, evidences)
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
    |> elem(0)
    |> then(fn id -> id && Map.get(lm.hypotheses, id) end)

  top =
    case counted do
      nil -> []
      hypotheses -> hypotheses.evidence |> Enum.sort(:desc) |> Enum.take(5) |> Enum.map(&Float.round(&1 * 1.0, 2))
    end

  pose =
    case lm.possible_matches do
      [object_id] -> spread.(lm, object_id)
      many -> "#{length(many)} objects possible"
    end

  IO.puts(
    "#{String.pad_leading("#{step}", 4)} | #{lm.symmetry_evidence}, " <>
      "#{inspect(lm.terminal_state)}, #{String.pad_trailing(pose, 44)} " <>
      "#{String.pad_trailing("#{counted && Hypotheses.count(counted)} of them, top #{inspect(top)}", 40)} | " <>
      "#{monty.(step)} | #{monty_space.(Enum.at(monty_evidence, monty_offset + step))}"
  )
end

Model.stop(id)
