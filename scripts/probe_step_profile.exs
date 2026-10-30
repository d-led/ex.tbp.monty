# Where one step's second goes, function by function.
#
#   MIX_ENV=test mix run scripts/probe_step_profile.exs
#
# `probe_state_cost.exs` shows the coordinator holds the learning module's
# 44 MB pretrained state, and that one `Model.state/1` copy costs ~200 ms, but
# a step costs 0.75-1.9 s. This profiles the processes one step touches, so the
# seconds can be attributed instead of guessed at.

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

servers = [
  GenServer.whereis(Registry.via({:step, id})),
  GenServer.whereis(Registry.via({:learning_module, id, module_id})),
  GenServer.whereis(Registry.via({:sensor_module, id, "patch"}))
]

{wall, info} =
  :timer.tc(fn ->
    :eprof.start()
    :eprof.start_profiling(servers)
    {:ok, _actions, info} = Model.step(id, %{}, %{}, Monty.Context.new(0))
    :eprof.stop_profiling()
    info
  end)

IO.puts(
  "step 0 took #{div(wall, 1000)} ms with profiling on; it timed itself at #{info.duration_us} us"
)

IO.puts("\n== where the time went ==")
:eprof.analyze(:total_time, sort: :time)

Model.stop(id)
