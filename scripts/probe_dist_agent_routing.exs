# Does the percept reach the module through the coordinator, and does the
# evidence grow the way Monty's did?
#
#   MIX_ENV=test mix run scripts/probe_dist_agent_routing.exs
#
# The learning module on its own reproduces Monty's evidence exactly
# (`probe_dist_agent_evidence.exs`), but the episode does not conclude
# (`probe_dist_agent_episodes.exs`). This steps the same model through the
# coordinator and reads the module's evidence after each step:
#
#   * evidence stays zero -> the percept never reaches the module (routing);
#   * evidence grows but never matches -> the terminal condition, not the inputs;
#   * evidence matches Monty's -> only the coordinator's ending differs.

alias Monty.Runtime.{LearningModuleServer, Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"
steps = 5

{:ok, opened} = Monty.Studio.open(experiment)
[percepts_per_step | _more] = MontyRecording.episodes!(recording)
monty = MontyRecording.evidence_over_steps!(recording)

top = fn evidence ->
  evidence
  |> Enum.reject(fn {_id, value} -> value == 0 end)
  |> Enum.sort_by(fn {_id, value} -> -value end)
  |> Enum.take(3)
  |> Enum.map_join(" ", fn {id, value} -> "#{id}=#{Float.round(value * 1.0, 3)}" end)
end

id = "probe-routing-#{System.unique_integer([:positive])}"

spec = Setup.model_spec(opened.setup, id)
# The learning module the config builds, by the id it was given: wiring the
# sensor to a module id that does not exist is a run where nothing is ever
# perceived, and it looks exactly like a model that cannot recognise.
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

{:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})
:ok = Model.set_experiment_mode(id, :eval)

IO.puts("step | what Monty held              | what the module holds through the coordinator")

for step <- 0..(steps - 1) do
  {:ok, _actions, info} = Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step})
  lm = LearningModuleServer.state(Registry.via({:learning_module, id, module_id}))
  {ids, values} = Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM.evidence_for_each_graph(lm)
  ours = Map.new(Enum.zip(ids, values))

  IO.puts(
    "#{String.pad_leading("#{step}", 4)} | #{String.pad_trailing(top.(Enum.at(monty, step, %{})), 28)} | " <>
      "#{top.(ours)}   [inputs #{inspect(info.inputs)}, percepts #{inspect(info.percept_ids)}]"
  )
end

Model.stop(id)
