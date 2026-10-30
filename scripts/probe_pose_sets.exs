# Which poses each side still considers possible, step by step.
#
#   MIX_ENV=test mix run scripts/probe_pose_sets.exs [episode] [steps]
#
# The dice episode ends one step apart: Monty's symmetry count reaches five on
# its last step and the port's resets there (`probe_episode_conclusion.exs`). The
# symmetry rule is "at least 90% of this step's possible poses were possible last
# step", so this prints the two sets and each side's overlap with its own previous
# step: a set that differs by a pose or two is rounding in the evidence, a set
# that differs wholesale is the membership test itself.

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
    [episode] -> [String.to_integer(episode), 40]
    [] -> [7, 40]
  end

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)

episodes = MontyRecording.episodes!(recording)
percepts_per_step = Enum.at(episodes, episode - 1)
monty_offset = episodes |> Enum.take(episode - 1) |> Enum.map(&length/1) |> Enum.sum()
monty_conditions = MontyRecording.terminal_conditions!(recording)

# Monty keeps the ids it compared when there are few enough of them.
monty_ids =
  recording
  |> File.stream!()
  |> Enum.map(fn line ->
    line
    |> Jason.decode!()
    |> get_in(["learning_modules", "learning_module_0", "state", "unique_poses"])
    |> Kernel.||(%{})
    |> Map.get("ids")
  end)

id = "probe-sets-#{System.unique_integer([:positive])}"
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

overlap = fn last, now ->
  case {last, now} do
    {[], _} -> "no history"
    {_, []} -> "none possible"
    {last, now} ->
      shared = MapSet.intersection(MapSet.new(last), MapSet.new(now)) |> MapSet.size()
      "#{shared}/#{length(now)} = #{Float.round(shared / length(now) * 1.0, 2)}"
  end
end

IO.puts("step | port: poses, overlap with its last step, symmetry | Monty")

{_last_port, _} =
  Enum.reduce(0..(steps - 1), {[], nil}, fn step, {last_port, _} ->
    {:ok, _actions, _info} = Model.step(id, %{}, %{}, %{Monty.Context.new(0) | step: step})
    lm = LearningModuleServer.state(server)

    now_port =
      case lm.possible_matches do
        [object_id] -> EvidenceGraphLM.get_possible_hypothesis_ids(lm, object_id)
        _many -> []
      end

    index = monty_offset + step
    now_monty = Enum.at(monty_ids, index) || []
    last_monty = if index > 0, do: Enum.at(monty_ids, index - 1) || [], else: []
    conditions = Enum.at(monty_conditions, index)

    IO.puts(
      "#{String.pad_leading("#{step}", 4)} | " <>
        "#{String.pad_trailing("#{length(now_port)} poses, #{overlap.(last_port, now_port)}, sym #{lm.symmetry_evidence}", 40)} | " <>
        "#{if conditions, do: "#{length(now_monty)} poses, #{overlap.(last_monty, now_monty)}, sym #{conditions.symmetry}", else: "—"}"
    )

    {now_port, nil}
  end)

Model.stop(id)
