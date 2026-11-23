defmodule Monty.Frameworks.Actions.ActionSamplers.ActionSamplerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.ActionSamplers.{ActionSampler, ConstantSampler}

  alias Monty.Frameworks.Actions.{LookDown, LookUp, MoveForward, TurnLeft, TurnRight}

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

  # The four actions `distant_5` gives its policy to choose between.
  defp distant_sampler do
    ConstantSampler.new(
      actions: [LookUp, LookDown, TurnLeft, TurnRight],
      rotation_degrees: 5.0
    )
  end

  # The episode's own stream, which is what a policy draws from in a run.
  defp context(seed), do: Monty.EpisodeStream.context(seed)

  defp draw(ctx, sampler \\ nil) do
    action = ActionSampler.sample(sampler || sampler(), @agent, ctx)
    action.__struct__.name()
  end

  describe "choosing which action to make" do
    test "draws more than one kind of action from a list of several" do
      ctx = context(1)

      actions = for _step <- 1..100, do: draw(ctx)

      # Monty's own test: 100 draws will not all be the same action.
      assert actions |> Enum.uniq() |> length() > 1
    end

    test "only ever makes the actions it was configured with" do
      ctx = context(1)

      names = for _step <- 1..50, do: draw(ctx)

      assert Enum.all?(names, &(&1 in ~w(look_down move_forward turn_left)))
    end

    test "a drawn action is the one asking for its kind would have made" do
      ctx = context(1)
      action = ActionSampler.sample(sampler(), @agent, ctx)

      asked_directly =
        apply(ConstantSampler, :"sample_#{action.__struct__.name()}", [
          sampler(),
          @agent,
          Monty.Context.rng(ctx)
        ])

      assert action == asked_directly
    end
  end

  describe "the episode's stream is where an action is chosen" do
    # numpy.random.RandomState(42).choice(4), ten times: the walk a `distant_5`
    # policy takes, one choice a step, over the four actions above in order.
    @numpy_seed_42 ~w(turn_left turn_right look_up turn_left turn_left turn_right look_up look_up turn_left look_down)

    test "a walk is numpy's choice series for the episode's seed" do
      ctx = context(42)

      walk = for _step <- 1..10, do: draw(ctx, distant_sampler())

      assert walk == @numpy_seed_42
    end

    test "the same episode draws the same walk" do
      assert walk(context(7), 5) == walk(context(7), 5)
    end

    test "a different episode seed draws a different walk" do
      refute walk(context(7), 5) == walk(context(0), 5)
    end

    test "two draws in one step are not forced to be the same action" do
      # What a policy does when it samples a direction and then a distance: the
      # second draw must be able to differ from the first.
      ctx = context(42)

      pairs = for _step <- 1..50, do: {draw(ctx, distant_sampler()), draw(ctx, distant_sampler())}

      assert Enum.any?(pairs, fn {first, second} -> first != second end)
    end

    test "a context with no stream says so instead of drawing another one" do
      assert_raise ArgumentError, ~r/no episode stream/, fn ->
        ActionSampler.sample(sampler(), @agent, Monty.Context.new(7))
      end
    end
  end

  defp walk(ctx, steps), do: for(_step <- 1..steps, do: draw(ctx, distant_sampler()))
end
