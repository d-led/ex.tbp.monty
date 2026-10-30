# One graph's hypotheses, step by step, from the port — Monty's beside them.
#
#   MIX_ENV=test mix run scripts/probe_replay_hypotheses.exs [episode] [graph] [steps] [out.jsonl]
#
# `probe_replay_graphs.exs` compares a graph's best evidence. This goes one level
# down: every hypothesis, with the location and pose it sits at, so the two
# implementations' numbers can be diffed one hypothesis at a time instead of
# through a maximum that hides which of them disagreed.
#
# The counterpart is the recorder with `MONTY_RECORD_EVIDENCE=1`, which writes
# the same three arrays from Monty (`scripts/record_monty_episode.py`). A step
# that starts to differ is then a step where some hypotheses score differently,
# and the places those hypotheses sit say which part of the arithmetic to read.
#
# The episode runs on Monty's own percepts — the recording is the world — so
# nothing sensor-side is involved and any difference is the module's.

alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

fixture = "test/fixtures/monty_dist_agent_10episodes.jsonl"
episode = System.argv() |> Enum.at(0) |> then(&if(&1, do: String.to_integer(&1), else: 5))
graph = System.argv() |> Enum.at(1) || "c_lego_duplo"
steps = System.argv() |> Enum.at(2) |> then(&if(&1, do: String.to_integer(&1), else: 3))
out = System.argv() |> Enum.at(3) || "/tmp/port-hypotheses.jsonl"

Code.require_file("probe_support.exs", __DIR__)
%{setup: setup} = ProbeSupport.setup("base_config_10distinctobj_dist_agent")

percepts =
  fixture
  |> MontyRecording.episodes!()
  |> Enum.at(episode - 1)
  |> Enum.map(fn
    [] -> nil
    [percept | _rest] -> percept
  end)

id = "hypotheses-#{System.unique_integer([:positive])}"
spec = Setup.model_spec(setup, id)
module_id = hd(spec.learning_modules).id

spec =
  spec
  |> Map.put(:sensor_modules, [
    %{
      id: "patch",
      agent_id: Environment.agent_id(),
      module: Recording.SensorModule,
      state: Recording.SensorModule.new("patch", percepts)
    }
  ])
  |> Map.drop([:motor])

{:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})
lm = Registry.via({:learning_module, id, module_id})

dump = fn step ->
  case LearningModuleServer.state(lm).hypotheses do
    %{^graph => space} ->
      Jason.encode!(%{
        "episode" => episode,
        "step" => step,
        "graph" => graph,
        "evidence" => space.evidence,
        "locations" => space.locations,
        "poses" => space.poses
      })

    _ ->
      Jason.encode!(%{"episode" => episode, "step" => step, "graph" => graph, "evidence" => []})
  end
end

run =
  Episode.run(
    id,
    fn _actions ->
      Process.put(:seen, [dump.(Process.get(:calls, 0) + 1) | Process.get(:seen, [])])
      Process.put(:calls, Process.get(:calls, 0) + 1)
      {%{Environment.agent_id() => %{}}, %{}}
    end,
    mode: :eval,
    max_steps: min(steps, length(percepts))
  )

# The callback runs before each step, so the last state is read here rather than
# inside it: after `steps` steps it is what the recording's last line holds.
last = dump.(run.steps)
Model.stop(id)

lines = Process.get(:seen, []) |> Enum.reverse() |> Enum.drop(1) |> Kernel.++([last])
File.write!(out, Enum.join(lines, "\n") <> "\n")

IO.puts("#{length(lines)} states of #{graph} in episode #{episode} → #{out}")
