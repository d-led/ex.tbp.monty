# Who decodes the evidence columns. `tprof` keeps no call graph and `cprof` keeps
# no caller, so this uses `eprof` and names the caller instead of inviting a guess.
#
#   MIX_ENV=test mix run scripts/probe_decode_callers.exs

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

id = "probe-decode-#{System.unique_integer([:positive])}"
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

# One step to warm the code paths, then the next one profiled. The work happens
# in the model's own processes, not in the caller: a step is a `GenServer.call`,
# so profiling the caller profiles a process that is asleep.
{:ok, _actions, _info} = run.()

pids =
  Enum.flat_map([{:step, id} | Enum.map(spec.learning_modules, &{:learning_module, id, &1.id})], fn key ->
    key |> Registry.lookup() |> Enum.map(&elem(&1, 0))
  end) ++
    Enum.map(spec.sensor_modules, fn sm ->
      [{pid, _}] = Registry.lookup({:sensor_module, id, sm.id})
      pid
    end)

IO.puts("profiling #{length(pids)} of the model's processes")

:eprof.start()
:eprof.start_profiling(pids)
{:ok, _actions, info} = run.()
:eprof.stop_profiling()
:eprof.analyze(:total)
:eprof.stop()

IO.puts("\nthat step: #{div(info.duration_us, 1000)} ms")
Model.stop(id)
