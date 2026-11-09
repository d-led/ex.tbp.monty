# Which of the graph reads happen on every step, and how often. cprof counts
# calls; the question is whether `length/1` over a graph's nodes is in the step.
#
#   MIX_ENV=test mix run scripts/probe_graph_reads.exs

alias Monty.Runtime.{Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)
[percepts_per_step | _more] = MontyRecording.episodes!(recording)

id = "probe-reads-#{System.unique_integer([:positive])}"
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

{:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})
:ok = Model.set_experiment_mode(id, :eval)

run = fn -> Model.step(id, %{}, %{}, Monty.Context.new(0)) end

# One step to warm, then the next one counted.
{:ok, _actions, _info} = run.()

:cprof.start()

{:ok, _actions, info} = run.()

modules = [
  Monty.Frameworks.Models.ObjectModel.GraphObjectModel,
  Monty.Frameworks.Models.GraphMatching.GraphMemory,
  Monty.Frameworks.Models.EvidenceMatching.Hypotheses
]

Module.concat([Mod]) |> then(fn _ -> :cprof.analyse(:total, limit: 12) end)

IO.puts("\nthat step: #{div(info.duration_us, 1000)} ms")
Model.stop(id)
