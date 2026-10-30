# Monty's own percepts, stepped through the port one at a time — evidence and
# hypothesis counts compared at every step, not at the end.
#
#   MIX_ENV=test mix run scripts/probe_replay_graphs.exs [episode] [fixture]
#
# `probe_dist_agent_episodes.exs` replays a recording and asks whether the port
# reaches Monty's conclusion. That answer is a single bit per episode, and it
# cannot say where two implementations parted. This probe asks the same question
# of every step: with the percepts held identical — the recording is the world,
# so nothing sensor-side can differ — do the module's evidence, its hypothesis
# counts and its spread inside the 20 % band come out the same?
#
# If they do, a live difference is sensor arithmetic arriving at a percept a
# nanometre off, amplified. If they do not, there is a difference in the module
# itself, and the first step it shows is where to look.

alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

fixture = Enum.at(System.argv(), 1) || "test/fixtures/monty_dist_agent_10episodes.jsonl"
wanted = System.argv() |> List.first() |> then(&if(&1, do: String.to_integer(&1), else: 5))

experiment = "base_config_10distinctobj_dist_agent"
channel = "patch"

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)
setup = opened.setup
episodes = MontyRecording.episodes!(fixture)

# The recording holds every episode in one file, so the per-step maps are one
# long list; the episode lengths are what says which step belongs to which.
recorded = MontyRecording.graph_evidence!(fixture)
offset = episodes |> Enum.take(wanted - 1) |> Enum.map(&length/1) |> Enum.sum()

# A step is the list of messages the module was given — usually one, and empty
# on the steps the sensor was silent. The sensor hands back one percept a step,
# so the list is flattened here; passing the list itself feeds the module a list
# where it expects a percept, and the module then accumulates nothing at all.
percepts =
  episodes
  |> Enum.at(wanted - 1)
  |> Enum.map(fn
    [] -> nil
    [percept | _rest] -> percept
  end)

monty = recorded |> Enum.drop(offset) |> Enum.take(length(percepts))

# The module's own numbers, in the recorder's own field names, so the two sides
# are compared as the same thing rather than as two lookalike shapes.
graphs = fn lm ->
  lm.hypotheses
  |> Enum.reject(fn {_graph_id, space} -> space.evidence == [] end)
  |> Map.new(fn {graph_id, space} ->
    scores = space.evidence
    best = Enum.max(scores)

    within =
      if best > 0,
        do: Enum.count(scores, &(&1 > best - best / 100 * lm.x_percent_threshold)),
        else: 0

    {graph_id,
     %{
       "hypotheses" => length(scores),
       "max_evidence" => best,
       "within_x_percent" => within
     }}
  end)
end

id = "replay-#{System.unique_integer([:positive])}"
spec = Setup.model_spec(setup, id)
module_id = hd(spec.learning_modules).id

# Only the sensor is replaced — the recording is the world. The module's wiring
# stays the config's: a learning module told it has no one to vote with is not
# asked to match at all, and an empty module reads exactly like a module that
# cannot recognise anything.
spec =
  spec
  |> Map.put(:sensor_modules, [
    %{
      id: channel,
      agent_id: Environment.agent_id(),
      module: Recording.SensorModule,
      state: Recording.SensorModule.new(channel, percepts)
    }
  ])
  |> Map.drop([:motor])

{:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})

# The callback runs before each step, in the episode's own process, so what it
# reads is the state the previous step left behind: the list ends up as "after 0
# steps, after 1 step, ...", which lines up with the recording's lines.
lm = Registry.via({:learning_module, id, module_id})

run =
  Episode.run(
    id,
    fn _actions ->
      Process.put(:seen, [graphs.(LearningModuleServer.state(lm)) | Process.get(:seen, [])])
      {%{Environment.agent_id() => %{}}, %{}}
    end,
    mode: :eval,
    max_steps: length(percepts)
  )

after_steps = Process.get(:seen, []) |> Enum.reverse()
final = graphs.(LearningModuleServer.state(lm))
Model.stop(id)

# "After 0 steps" is an empty module; the recording's first line is after one.
port = Enum.drop(after_steps, 1) ++ [final]

IO.puts("episode #{wanted}: Monty #{length(percepts)} steps, port ran #{run.steps}")
IO.puts(String.duplicate("-", 78))
IO.puts("step | object      | evidence port / Monty          | hyps port/Monty | within")

first_evidence = Enum.find_index(Enum.zip(port, monty), fn {p, m} ->
  Enum.any?(m, fn {g, v} ->
    case p[g] do
      nil -> true
      _ -> abs(p[g]["max_evidence"] - v["max_evidence"]) > 1.0e-6
    end
  end)
end)

first_counts = Enum.find_index(Enum.zip(port, monty), fn {p, m} ->
  Enum.any?(m, fn {g, v} ->
    case p[g] do
      nil -> true
      _ -> p[g]["hypotheses"] != v["hypotheses"]
    end
  end)
end)

show = fn from ->
  port
  |> Enum.zip(monty)
  |> Enum.with_index(1)
  |> Enum.drop(from)
  |> Enum.take(10)
  |> Enum.each(fn {{p, m}, step} ->
    Enum.each(Enum.sort(Map.keys(m)), fn g ->
      pv = p[g] || %{"max_evidence" => -1.0, "hypotheses" => 0, "within_x_percent" => 0}
      mv = m[g]

      IO.puts(
        String.pad_leading("#{step}", 4) <>
          " | " <>
          String.pad_trailing(g, 11) <>
          " | " <>
          String.pad_trailing("#{Float.round(pv["max_evidence"], 9)} / #{Float.round(mv["max_evidence"], 9)}", 30) <>
          " | " <>
          String.pad_trailing("#{pv["hypotheses"]}/#{mv["hypotheses"]}", 15) <>
          " | #{pv["within_x_percent"]}/#{mv["within_x_percent"]}"
      )
    end)
  end)
end

IO.puts(
  "first evidence difference: " <>
    if(first_evidence, do: "after #{first_evidence} steps", else: "none within 1e-6")
)

IO.puts(
  "first count difference:    " <>
    if(first_counts, do: "after #{first_counts} steps", else: "none")
)

# Evidence is a sum of increments, so a difference that grows with the steps is
# arithmetic piling up; one that stands whole at a single step is a step the two
# scored differently. Per object: the worst step, and where it first passed a
# tenth of a percent — the size below which a difference is the last bits.
IO.puts("\nobject         | steps | worst relative | first over 1e-3 | count differs")
IO.puts(String.duplicate("-", 78))

port
|> Enum.zip(monty)
|> Enum.with_index(1)
|> Enum.flat_map(fn {{p, m}, step} ->
  Enum.map(m, fn {g, v} ->
    pv = p[g]

    rel =
      if pv,
        do: abs(pv["max_evidence"] - v["max_evidence"]) / max(v["max_evidence"], 1.0e-9),
        else: 1.0

    {g, step, rel, pv && pv["hypotheses"], v["hypotheses"]}
  end)
end)
|> Enum.group_by(&elem(&1, 0))
|> Enum.sort()
|> Enum.each(fn {g, rows} ->
  worst = Enum.max_by(rows, &elem(&1, 2))
  first_over = Enum.find(rows, fn row -> elem(row, 2) > 1.0e-3 end)
  count_diffs = Enum.count(rows, fn row -> elem(row, 3) != elem(row, 4) end)

  IO.puts(
    String.pad_trailing(g, 14) <>
      " | " <>
      String.pad_leading("#{length(rows)}", 5) <>
      " | " <>
      String.pad_leading("#{Float.round(elem(worst, 2) * 100, 4)}%", 14) <>
      " | " <>
      String.pad_trailing(if(first_over, do: "step #{elem(first_over, 1)}", else: "none"), 16) <>
      " | #{count_diffs} of #{length(rows)}"
  )
end)

show.(max((first_counts || 0) - 2, 0))

# Step by step, the object furthest from Monty's — enough to see whether a
# difference arrives whole at one step (a step scored differently) or creeps in
# with the arithmetic.
IO.puts("\nstep | worst object   | relative | evidence port / Monty")
IO.puts(String.duplicate("-", 78))

port
|> Enum.zip(monty)
|> Enum.with_index(1)
|> Enum.each(fn {{p, m}, step} ->
  {g, rel, pv} =
    m
    |> Enum.map(fn {g, v} ->
      pv = p[g] || %{"max_evidence" => -1.0}

      {g, abs(pv["max_evidence"] - v["max_evidence"]) / max(v["max_evidence"], 1.0e-9), pv}
    end)
    |> Enum.max_by(&elem(&1, 1))

  IO.puts(
    String.pad_leading("#{step}", 4) <>
      " | " <>
      String.pad_trailing(g, 15) <>
      " | " <>
      String.pad_leading("#{Float.round(rel * 100, 5)}%", 8) <>
      " | " <>
      "#{Float.round(pv["max_evidence"], 9)} / #{Float.round(m[g]["max_evidence"], 9)}"
  )
end)
