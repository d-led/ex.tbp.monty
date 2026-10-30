# The studio's own run path, against Monty's world, watched to the end.
#
#   MONTY_WORLD=habitat \
#   MONTY_PYTHON="$(conda info --base)/envs/tbp.monty/bin/python" \
#     mix run scripts/probe_studio_habitat_run.exs [experiment] [steps]
#
# Unlike `probe_world_studio_run.exs`, which steps a run in this process, this
# goes the way the page goes: it writes a run record, enqueues the job and waits
# for the queue. So it exercises the whole path a reader sees — the record, the
# log, the per-step broadcast with its frames and beliefs, the summary — and
# leaves a run in the database for the page to show.
#
# It is a probe: a Habitat step plus a learning module's matching is about a
# second, so keep the step count small unless you mean it.

alias Monty.Studio.{Jobs, RunHistory, RunLog, Setup}

experiment = List.first(System.argv()) || "base_config_10distinctobj_dist_agent"
steps = System.argv() |> Enum.at(1) |> then(&(&1 && String.to_integer(&1))) || 12

unless Application.get_env(:ex_tbp_monty, :world_simulator) == :habitat do
  IO.puts("set MONTY_WORLD=habitat: this probe is about Monty's own world")
  System.halt(1)
end

{:ok, opened} = Monty.Studio.open(experiment)
IO.puts("experiment: #{opened.setup.name}, world: #{inspect(opened.setup.world)}")
IO.puts("peer: #{inspect(Setup.world(opened.setup).command)}")

{:ok, record} = RunHistory.start(RunLog.attributes(opened, steps))
Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))
IO.puts("run id: #{record.id}, world input: #{inspect(record.inputs["world"])}")

# The job is run in this process, not enqueued: the queue is in the database, so
# a `mix phx.server` sharing it would take the job and step *its* world.
job = %Oban.Job{args: %{"run_id" => record.id}}
result = Jobs.Run.perform(job)
IO.puts("perform: #{inspect(result)}")

walk = fn walk ->
  receive do
    {:step, %{step: step, frames: frames, beliefs: beliefs}} ->
      shown =
        Enum.map_join(frames, ", ", fn frame ->
          "#{frame.sensor_id}:#{byte_size(frame.data)}B"
        end)

      likely =
        Enum.map_join(beliefs, ", ", fn {module_id, belief} ->
          top = if belief.mlh, do: "#{belief.mlh.graph_id}@#{Float.round(belief.mlh.evidence, 3)}"
          "#{module_id} #{inspect(top)}"
        end)

      IO.puts("step #{step}: frames [#{shown}] | #{likely}")
      walk.(walk)

    {:finished, %{status: status, summary: summary}} ->
      IO.puts("finished: #{status}")
      IO.inspect(summary, label: "summary", limit: :infinity)

    {:failed, %{reason: reason}} ->
      IO.puts("failed: #{inspect(reason)}")

    {:started, planned} ->
      IO.puts("started, budget #{planned} step(s)")
      walk.(walk)

    _other ->
      walk.(walk)
  after
    5_000 -> IO.puts("no more messages")
  end
end

walk.(walk)
IO.puts("the run is in the database: open it in the studio's run history")
