# What a step through the coordinator spends its seconds on.
#
#   MIX_ENV=test mix run scripts/probe_state_cost.exs
#
# `probe_dist_agent_episodes.exs` takes 1-5 s per step where five hand-stepped
# steps take a second (`probe_dist_agent_routing.exs`). The loop's own addition
# to each step is one `Model.state/1` for the policy's view, so this times that
# call against a step itself, and prints how large the terms it copies are.

alias Monty.Runtime.{Model}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)
[percepts_per_step | _more] = MontyRecording.episodes!(recording)

id = "probe-cost-#{System.unique_integer([:positive])}"
spec = Setup.model_spec(opened.setup, id)
module_id = hd(spec.learning_modules).id

IO.puts(
  "learning module spec: #{byte_size(:erlang.term_to_binary(hd(spec.learning_modules).state))} bytes on the wire"
)

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

time = fn label, count, fun ->
  {micros, _} = :timer.tc(fn -> Enum.each(1..count, fn _ -> fun.() end) end)
  IO.puts("#{String.pad_trailing(label, 24)} #{div(micros, count)} us each")
end

time.("Model.state/1", 20, fn -> Model.state(id) end)
time.("Model.status/1", 20, fn -> Model.status(id) end)

for step <- 0..4 do
  {micros, {:ok, _actions, info}} =
    :timer.tc(fn -> Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step}) end)

  IO.puts("step #{step}: #{div(micros, 1000)} ms  [#{info.step_type}]")
end

time.("Model.state/1 (after)", 20, fn -> Model.state(id) end)
time.("Model.status/1 (after)", 20, fn -> Model.status(id) end)

Model.stop(id)
