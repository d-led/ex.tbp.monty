# How long a step takes through `Episode.run`, and where the time goes.
#
#   MIX_ENV=test mix run scripts/probe_episode_timing.exs
#
# `scripts/probe_dist_agent_episodes.exs` takes minutes per episode where five
# hand-stepped steps take a second (`probe_dist_agent_routing.exs`). Same model,
# same percepts, same coordinator — so the difference is in the loop, and this
# prints the wall time of every step of one episode to find it.

alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)
[percepts_per_step | _more] = MontyRecording.episodes!(recording)

id = "probe-timing-#{System.unique_integer([:positive])}"
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

# The environment is asked once per step, so timing it times the loop's steps.
started = System.monotonic_time(:millisecond)
last = :atomics.new(1, [])

environment = fn _actions ->
  at = System.monotonic_time(:millisecond)
  previous = :atomics.exchange(last, 1, at)
  step_ms = if previous == 0, do: at - started, else: at - previous
  IO.puts("  +#{step_ms} ms since the last step")
  {%{Environment.agent_id() => %{}}, %{Environment.agent_id() => %{}}}
end

{took, result} = :timer.tc(fn -> Episode.run(id, environment, mode: :eval) end)

IO.puts(
  "episode: #{result.steps} steps, done? #{result.done?}, timed_out? #{result.timed_out?}, " <>
    "#{div(took, 1000)} ms total, #{div(took, max(result.steps, 1) * 1000)} ms per step"
)

IO.puts("conclusion: #{inspect(result.terminal_states)}")
IO.puts("object: #{inspect(LearningModuleServer.state(Registry.via({:learning_module, id, module_id})).detected_object)}")

Model.stop(id)
