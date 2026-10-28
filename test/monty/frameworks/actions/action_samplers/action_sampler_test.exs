defmodule Monty.Frameworks.Actions.ActionSamplers.ActionSamplerTest do
  use ExUnit.Case, async: true

  alias Monty.Context

  alias Monty.Frameworks.Actions.ActionSamplers.{
    ActionSampler,
    ConstantSampler,
    UniformlyDistributedSampler
  }

  alias Monty.Frameworks.Actions.{LookDown, MoveForward, TurnLeft}

  @agent "agent_id_0"

  # Three actions with different parameters, so a wrong pick is visible in the
  # action as well as in its name.
  defp sampler do
    ConstantSampler.new(
      actions: [LookDown, MoveForward, TurnLeft],
      rotation_degrees: 7.0,
      translation_distance: 0.02
    )
  end

  defp state, do: :rand.seed_s(:exsss, {1, 2, 3})

  describe "choosing which action to make" do
    test "draws more than one kind of action from a list of several" do
      {actions, _state} =
        Enum.map_reduce(1..100, state(), fn _step, rng ->
          ActionSampler.sample(sampler(), @agent, rng)
        end)

      # Monty's own test: 100 draws will not all be the same action.
      assert actions |> Enum.map(& &1.__struct__) |> Enum.uniq() |> length() > 1
    end

    test "only ever makes the actions it was configured with" do
      {actions, _state} =
        Enum.map_reduce(1..50, state(), fn _step, rng ->
          ActionSampler.sample(sampler(), @agent, rng)
        end)

      assert Enum.all?(actions, &(&1.__struct__ in [LookDown, MoveForward, TurnLeft]))
    end

    test "a drawn action is the one asking for its kind would have made" do
      constant = sampler()
      {action, _rng} = ActionSampler.sample(constant, @agent, state())

      {asked_directly, _rng} =
        apply(ConstantSampler, :"sample_#{action.__struct__.name()}", [constant, @agent, state()])

      assert action == asked_directly
    end
  end

  describe "where the stream comes from" do
    test "a sampler with no stream yet takes one from the context" do
      context = Context.new(7)

      assert ActionSampler.stream(sampler(), nil, context) ==
               Context.rng_for(context, ConstantSampler)
    end

    test "a stream already in hand is the one used" do
      in_hand = state()

      assert ActionSampler.stream(sampler(), in_hand, Context.new(7)) == in_hand
    end

    test "the same episode and step draw the same action" do
      context = Context.new(7)

      assert draw_from_context(context) == draw_from_context(context)
    end

    test "two kinds of sampler in the same step draw from different streams" do
      context = Context.new(7)

      assert ActionSampler.stream(sampler(), nil, context) !=
               ActionSampler.stream(
                 UniformlyDistributedSampler.new(actions: [LookDown]),
                 nil,
                 context
               )
    end
  end

  describe "threading the stream" do
    test "a draw advances the stream, so the next draw is a new one" do
      {_action, rng} = ActionSampler.sample(sampler(), @agent, state())

      assert rng != state()
    end

    test "two draws in one step are not forced to be the same action" do
      # What a policy does when it samples a direction and then a distance: the
      # second draw must be able to differ from the first, which a stream keyed
      # to the step alone could never do.
      {pairs, _rng} =
        Enum.map_reduce(1..50, state(), fn _draw, rng ->
          {first, rng} = ActionSampler.sample(sampler(), @agent, rng)
          {second, rng} = ActionSampler.sample(sampler(), @agent, rng)

          {{first.__struct__, second.__struct__}, rng}
        end)

      assert Enum.any?(pairs, fn {first, second} -> first != second end)
    end
  end

  defp draw_from_context(context) do
    rng = ActionSampler.stream(sampler(), nil, context)
    {action, _rng} = ActionSampler.sample(sampler(), @agent, rng)

    action
  end
end
