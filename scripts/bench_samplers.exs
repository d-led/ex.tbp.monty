# What threading a sampler's stream saves over rederiving it every draw.
#
# Monty passes a mutable `RandomState` into every `sample` call and mutates it in
# place, so one stream advances across the episode. Elixir cannot mutate it, so
# the sampler answers the state it leaves behind and the policy threads it
# (`docs/monty-bugs.md` §2.5). The alternative a context-shaped API would offer
# is to reseed per draw from `Context.rng_for/2`, which needs no state in the
# caller. This script prices that alternative.
#
#     MIX_ENV=test mix run scripts/bench_samplers.exs
#
# Recorded 2026-10-28, Apple M-series, Elixir 1.20.4 / OTP 29:
#
#     threaded draws                1.00-1.08us per draw
#     reseeded draws                1.43-1.46us per draw
#     so threading saves            0.33-0.45us per draw
#     a matching step, for scale    ~39ms median
#     so either way                 under 0.004% of a step
#
# Which is not why threading was chosen: at one or two sampled actions per step
# neither cost matters. The reason is that a policy samples more than once in a
# step — `SurfacePolicy` a direction and then a distance — and a stream keyed to
# the step alone would answer every one of those draws with the same action.
# Threading costs less and is the only shape that behaves like Monty's.

alias Monty.Context
alias Monty.Frameworks.Actions.{
  LookDown,
  LookUp,
  MoveForward,
  MoveTangentially,
  OrientHorizontal,
  OrientVertical,
  SetAgentPitch,
  SetAgentPose,
  SetSensorPitch,
  SetSensorPose,
  SetSensorRotation,
  SetYaw,
  TurnLeft,
  TurnRight
}

alias Monty.Frameworks.Actions.ActionSamplers.{ActionSampler, UniformlyDistributedSampler}

draws = 200_000
agent = "agent_id_0"

sampler =
  UniformlyDistributedSampler.new(
    actions: [
      LookDown,
      LookUp,
      MoveForward,
      MoveTangentially,
      OrientHorizontal,
      OrientVertical,
      SetAgentPitch,
      SetAgentPose,
      SetSensorPitch,
      SetSensorPose,
      SetSensorRotation,
      SetYaw,
      TurnLeft,
      TurnRight
    ]
  )

# One episode, many steps: the shape a run actually has.
contexts = for step <- 0..(draws - 1), do: %{Context.new(7) | step: step}

{threaded_us, {threaded_actions, _rng}} =
  :timer.tc(fn ->
    Enum.map_reduce(contexts, Context.rng_for(Context.new(7), UniformlyDistributedSampler), fn _ctx, rng ->
      ActionSampler.sample(sampler, agent, rng)
    end)
  end)

{reseeded_us, reseeded_actions} =
  :timer.tc(fn ->
    Enum.map(contexts, fn ctx ->
      {action, _rng} =
        ActionSampler.sample(
          sampler,
          agent,
          Context.rng_for(ctx, UniformlyDistributedSampler)
        )

      action
    end)
  end)

per_draw = fn micros -> micros / draws end

IO.puts("""
draws: #{draws}
  threaded (what the policies do)   #{Float.round(per_draw.(threaded_us), 3)}us each
  reseeded per draw                 #{Float.round(per_draw.(reseeded_us), 3)}us each
  threading saves                   #{Float.round(per_draw.(reseeded_us) - per_draw.(threaded_us), 3)}us each
  a matching step, for scale        ~38_500us
  so one sampled action             #{Float.round(per_draw.(threaded_us) / 38_500 * 100, 5)}% of a step
""")

# Both must start from the same stream, or the comparison is between two
# samplers rather than between two ways of reaching one.
if hd(threaded_actions) != hd(reseeded_actions) do
  raise """
  the two drew different actions from the same seed and step:
    threaded: #{inspect(hd(threaded_actions))}
    reseeded: #{inspect(hd(reseeded_actions))}
  """
end

IO.puts("both drew #{hd(threaded_actions).__struct__.name()} from the same seed and step")
