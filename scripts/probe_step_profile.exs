# Where one step's second goes, function by function.
#
#   MIX_ENV=test mix run scripts/probe_step_profile.exs
#
# `probe_state_cost.exs` shows the coordinator holds the learning module's
# 44 MB pretrained state, and that one `Model.state/1` copy costs ~200 ms, but
# a step costs 0.75-1.9 s. This profiles the processes one step touches, so the
# seconds can be attributed instead of guessed at.
#
# `tprof` rather than `eprof`: a step hands work to processes the caller never
# names — the sensor modules' bursts, the graph's own passes — and eprof only
# sees the processes it was told about, which is why this used to print an empty
# table. `rootset: :all` sees every process the step spawns.

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

id = "probe-profile-#{System.unique_integer([:positive])}"
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

# One unprofiled step first: the first one loads code and warms the caches, and
# attributing its cost to the algorithms would be a lie. The profiled step is
# the second, so both report numbers a third step would repeat.
{:ok, _actions, _info} = run.()

{wall, {:ok, _actions, info}} = :timer.tc(run)

IO.puts("one step: #{div(wall, 1000)} ms, as it timed itself #{div(info.duration_us, 1000)} ms")

profile = fn type ->
  :tprof.profile(run, %{type: type, rootset: :all, report: {:total, {:measurement, :descending}}})
end

IO.puts("\n== where the memory went (words allocated) ==")
IO.puts(profile.(:call_memory))

IO.puts("\n== where the time went (scheduler time) ==")
IO.puts(profile.(:call_time))

Model.stop(id)
