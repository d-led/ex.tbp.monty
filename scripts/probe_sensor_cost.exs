# What each sensor costs in a step, and what a concurrent sensor phase would save.
#
#   MIX_ENV=test mix run scripts/probe_sensor_cost.exs [experiment] [steps] [world]
#
# `probe_step_phases.exs` splits a step into world / model and by kind of
# process. This one splits the model by *sensor*, because `Step.step_sensor_modules/4`
# asks them one at a time — a round each — and the question is what running them
# together would buy. It answers three numbers:
#
#   * per sensor, its own reductions and its share of the model's work;
#   * the sensor phase's total, against the model's;
#   * the same total as `max(sensor)` in place of `sum(sensor)`, which is what a
#     perfectly concurrent phase costs when there is a scheduler for every
#     sensor. That is an estimate, not a measurement: it assumes the sensors'
#     work is CPU bound and that the rounds themselves are free.
#
# Reductions are the currency (they do not move with the load on the box), and
# the wall clock is printed beside them only so a starved run can be told from a
# heavy one. Sensor work happens in the sensor's own process, so a sensor's
# share is read from the registry rather than from a timer around the barrier.
#
# **The estimate is only reachable where no sensor draws.** An episode has one
# random stream and the modules draw from it in the order they are stepped
# (`Monty.Random.Stream`), so a sensor that dithers or adds noise pins the phase
# to that order. Each sensor's own module state is printed beside its cost —
# `noise: nil` is the sensor saying that its step consumes nothing from the
# stream, and a salience module is the one that dithers on every informative
# step.

alias Monty.Context
alias Monty.Experiment.Environment.Interface
alias Monty.Runtime.Registry
alias Monty.Runtime.SensorModuleServer
alias Monty.Studio

experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"
steps = System.argv() |> Enum.at(1) |> then(&(&1 && String.to_integer(&1))) || 24

# The third argument names the world: `MIX_ENV=test` steps the synthetic
# stand-in unless told otherwise, and its numbers describe no MuJoCo run.
world = System.argv() |> Enum.at(2) |> then(&(&1 && String.to_existing_atom(&1)))

{:ok, opened} = Studio.open(experiment, if(world, do: [world_simulator: world], else: []))
{:ok, run} = Studio.Run.start(opened.setup, steps: steps * 10)
:ok = Studio.Run.set_ground_truth(run)

budget = :erlang.system_info(:schedulers_online)

# Every process the step talks to, named the way the registry names it.
parties = fn model_id ->
  Elixir.Registry.select(Monty.Runtime.Registry.registry(), [
    {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
  ])
  |> Enum.flat_map(fn {key, pid, _value} ->
    case key do
      {:step, ^model_id} -> [{{:coordinator, model_id}, pid}]
      {:random_stream, ^model_id} -> [{{:random_stream, model_id}, pid}]
      {kind, ^model_id, id} when kind in [:sensor_module, :learning_module] -> [{{kind, id}, pid}]
      _ -> []
    end
  end)
end

reductions = fn pid -> Process.info(pid, :reductions) |> elem(1) end

# A sensor's state says what its step is made of, and the module itself says
# whether its step draws: asking it is what the step coordinator asks, rather
# than a rule kept here that could drift from the module's own answer (`§2.28`).
describe = fn model_id, id ->
  state = SensorModuleServer.state(Registry.via({:sensor_module, model_id, id}))

  %{
    module: state.__struct__ |> Module.split() |> List.last(),
    draws?: state.__struct__.draws_from_stream?(state)
  }
end

IO.puts("#{experiment}: #{steps} steps, world #{world || :synthetic}, #{budget} schedulers online")

shapes =
  parties.(run.model_id)
  |> Enum.flat_map(fn
    {{:sensor_module, id}, _pid} -> [{id, describe.(run.model_id, id)}]
    _other -> []
  end)
  |> Map.new()

rows =
  Enum.map(1..steps, fn _ ->
    people = parties.(run.model_id)
    before = Map.new(people, fn {key, pid} -> {key, reductions.(pid)} end)

    {world_us, {observations, proprio, interface}} =
      :timer.tc(fn -> Interface.step(run.interface, run.pending_actions) end)

    {model_us, {:ok, actions, info}} =
      :timer.tc(fn ->
        Monty.Runtime.Model.step(
          run.model_id,
          observations,
          proprio,
          %{Context.new(run.episode_seed) | step: run.step}
        )
      end)

    run = %{
      run
      | interface: interface,
        step: run.step + 1,
        pending_actions: actions
    }

    %{
      step: info.step,
      processed?: info.processed?,
      world_us: world_us,
      model_us: model_us,
      work:
        Map.new(people, fn {key, pid} ->
          {key, reductions.(pid) - Map.fetch!(before, key)}
        end)
    }
  end)

report = fn label, rows ->
  case rows do
    [] ->
      IO.puts("\n#{label}: none in this window")

    _ ->
      n = length(rows)
      mean = fn field -> rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum() |> div(n) end

      by_kind = fn kind ->
        rows
        |> Enum.flat_map(fn row ->
          for {{^kind, id}, delta} <- row.work, do: {id, delta}
        end)
        |> Enum.group_by(fn {id, _} -> id end, fn {_, delta} -> delta end)
        |> Enum.map(fn {id, deltas} -> {id, div(Enum.sum(deltas), n)} end)
        |> Enum.sort_by(fn {_id, delta} -> -delta end)
      end

      sensors = by_kind.(:sensor_module)
      modules = by_kind.(:learning_module)
      total = Enum.reduce(rows, 0, fn row, sum -> sum + Enum.sum(Map.values(row.work)) end)

      drawing = for {id, %{draws?: true}} <- shapes, do: id

      IO.puts(
        "\n#{label}: #{n} steps\n" <>
          "  mean wall: world #{div(mean.(:world_us), 1000)} ms, model #{div(mean.(:model_us), 1000)} ms\n" <>
          "  mean work: #{div(total, n)} reductions a step, " <>
          "sensors #{div(Enum.sum(Enum.map(sensors, &elem(&1, 1))), max(n, 1))}, " <>
          "modules #{div(Enum.sum(Enum.map(modules, &elem(&1, 1))), max(n, 1))}"
      )

      Enum.each(sensors, fn {id, delta} ->
        IO.puts("  sensor #{id} (#{shapes[id].module}): #{delta} reductions/step")
      end)

      Enum.each(modules, fn {id, delta} ->
        IO.puts("  module #{id}: #{delta} reductions/step")
      end)

      sensor_sum = Enum.reduce(sensors, 0, fn {_id, delta}, sum -> sum + delta end)
      sensor_max = sensors |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
      percent = fn part -> Float.round(part * 100 / max(total, 1), 1) end

      IO.puts(
        "  the sensor phase is #{sensor_sum} reductions/step " <>
          "(#{percent.(sensor_sum)} % of the step); " <>
          "concurrent, #{sensor_max} (#{percent.(sensor_max)} %), " <>
          "a saving of #{percent.(sensor_sum - sensor_max)} % of the step"
      )

      case drawing do
        [] ->
          IO.puts("  no sensor drew from the stream: the phase may run in one round")

        ids ->
          IO.puts(
            "  these sensors draw: #{ids |> Enum.sort() |> Enum.join(", ")} " <>
              "— the phase is ordered until every one of them stops drawing"
          )
      end
  end
end

report.("processed", Enum.filter(rows, & &1.processed?))
report.("plain (location only)", Enum.reject(rows, & &1.processed?))
