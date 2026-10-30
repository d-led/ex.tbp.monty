# Which step the port concludes on, and what condition let it.
#
#   MIX_ENV=test mix run scripts/probe_episode_conclusion.exs [episode] [steps]
#
# `probe_dist_agent_episodes.exs` says the port recognises Monty's object, but
# on step 8 where Monty took 43 (`docs/validation.md`). The evidence agrees to
# the printed digit, so the difference is in what turns evidence into a
# conclusion: one object left, and a pose narrow enough to name — or enough
# consecutive steps of the same alternatives to call the object symmetric.
# This prints the module's own path beside Monty's recorded one.

alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
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
monty_evidence = MontyRecording.evidence_over_steps!(recording)
monty_hypotheses = MontyRecording.hypothesis_counts!(recording)
monty_poses = MontyRecording.mlh_ids!(recording)

# Monty's recording runs every episode end to end, so its rows are laid out one
# episode after another: the first episode's rows are the first ones recorded.
monty_step = fn step ->
  {evidence, hypotheses} =
    {Enum.at(monty_evidence, step, %{}), Enum.at(monty_hypotheses, step, %{})}

  best =
    evidence
    |> Enum.reject(fn {_id, value} -> value == 0 end)
    |> Enum.max_by(fn {_id, value} -> value end, fn -> {"-", 0} end)

  "#{inspect(best)} of #{inspect(Map.get(hypotheses, elem(best, 0)))}"
end

# Monty's own chosen pose, so the port's most likely hypothesis can be compared
# with the one Monty actually held: if those differ, a pose-uniqueness test that
# agrees in form is still measuring a different pose.
monty_pose = fn step -> Enum.at(monty_poses, step) end

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

opened_lm = LearningModuleServer.state(server)

IO.puts(
  "updater #{inspect(opened_lm.hypotheses_updater_module)}, x% #{opened_lm.x_percent_threshold}"
)

IO.puts("\nstep | port: objects, poses, symmetry, terminal, hypotheses | Monty")

for step <- 0..(steps - 1) do
  {:ok, _actions, _info} = Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step})
  lm = LearningModuleServer.state(server)

  {ids, evidences} = EvidenceGraphLM.evidence_for_each_graph(lm)
  {best_id, _evidence} = Enum.zip(ids, evidences) |> Enum.max_by(&elem(&1, 1))
  poses = length(EvidenceGraphLM.get_possible_hypothesis_ids(lm, best_id))
  counted = Map.get(lm.hypotheses, best_id)

  poser = lm.current_mlh

  IO.puts(
    "#{String.pad_leading("#{step}", 4)} | " <>
      "#{length(lm.possible_matches)} objects, #{poses} of #{Hypotheses.count(counted)} poses, " <>
      "sym #{lm.symmetry_evidence}, #{inspect(lm.terminal_state)} | " <>
      "#{monty_step.(step)} | pose #{inspect(poser && poser.mlh_id)}/#{inspect(monty_pose.(step))}"
  )
end

Model.stop(id)
