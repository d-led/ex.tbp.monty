# What an action draw costs now that it is the episode's stream.
#
#     MIX_ENV=test mix run scripts/bench_samplers.exs
#
# A sampler asks `Monty.Random.Stream` for numpy's `choice(count)`: one call into
# a process a draw, because that is where the episode's one stream lives
# (`docs/monty-differences.md` §2.1, §2.5). A step takes one or two of those, and
# what this answers is whether the call is visible at all next to a step. The
# in-process column is the same draw against a `Numpy` state held by the caller —
# the numbers are identical, so it prices the process boundary, not the maths.
#
# Recorded 2026-11-23, this Mac (macOS arm64), Elixir 1.20.5 / OTP 29, and a
# step of 18 ms measured separately (`base_config_10distinctobj_dist_agent`,
# `ex_mujoco`, 24 steps — `docs/roadmap.md` phase 3):
#
#     through the episode's stream   2.257us each
#     in process, same numbers       0.222us each
#     so one sampled action          0.013 % of a step
#
# The process call is ten times the arithmetic and still not a number a step can
# see: a step takes one or two actions, and a `SurfacePolicy` search a handful of
# draws. Rerun it rather than quote this line.

alias Monty.Frameworks.Actions.ActionSamplers.{ActionSampler, ConstantSampler}
alias Monty.Frameworks.Actions.{LookDown, LookUp, TurnLeft, TurnRight}
alias Monty.Random.{Numpy, Stream}

draws = 200_000
agent = "agent_id_0"

sampler =
  ConstantSampler.new(actions: [LookUp, LookDown, TurnLeft, TurnRight], rotation_degrees: 5.0)

model_id = "bench-#{System.unique_integer([:positive])}"
{:ok, _pid} = Stream.start_link(%{model_id: model_id, seed: 42})

stream = Stream.via(model_id)
context = %{Monty.Context.new(42) | rng: stream}

{through_stream_us, _actions} =
  :timer.tc(fn ->
    for _draw <- 1..draws, do: ActionSampler.sample(sampler, agent, context)
  end)

{in_process_us, _state} =
  :timer.tc(fn ->
    Enum.reduce(1..draws, Numpy.new(42), fn _draw, state ->
      {_index, state} = Numpy.choice(state, 4)
      state
    end)
  end)

per_draw = fn micros -> micros / draws end

IO.puts("""
draws: #{draws}
  through the episode's stream   #{Float.round(per_draw.(through_stream_us), 3)}us each
  in process, same numbers       #{Float.round(per_draw.(in_process_us), 3)}us each
  a step, for scale              ~18_000us
  so one draw                    #{Float.round(per_draw.(through_stream_us) / 18_000 * 100, 5)}% of a step
""")
