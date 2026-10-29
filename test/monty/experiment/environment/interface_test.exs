defmodule Monty.Experiment.Environment.InterfaceTest do
  @moduledoc """
  The interface steps the world, then transforms what came back — in order.

  `scripts/record_monty_interface.py` ran Monty's own `Interface` with a stub world
  that counts its steps and two transforms that tag the observations. What it
  recorded is the *sequence*: which transform ran, what it saw, and that each was
  handed a stream and a pose. The world here is the same kind of stub, so the
  test can put the port's sequence beside Monty's.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.Environment.Interface
  alias Monty.Frameworks.Actions.MoveForward
  alias Monty.InterfaceStubs.{StubWorld, Tagging}

  @fixture Path.expand("../../../fixtures/monty_interface.json", __DIR__)

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "each transform sees the previous one's answer, in the order configured", %{
    fixture: fixture
  } do
    %{"step" => %{"calls" => monty}} = fixture

    {observations, _pose, _interface} = Interface.step(interface(), [])

    assert observations["observations"] == ["after 1 steps", "first", "second"]

    assert seen_by_the_transforms() ==
             Enum.map(monty, fn %{
                                  "transform" => name,
                                  "saw" => saw,
                                  "has_state" => pose?,
                                  "has_rng" => stream?
                                } ->
               {name, saw, pose?, stream?}
             end)
  end

  test "the pose the world answered is handed back untouched", %{fixture: fixture} do
    %{"step" => %{"state" => monty_state}} = fixture

    {_observations, pose, _interface} = Interface.step(interface(), [])

    assert pose == monty_state
  end

  test "the world is stepped with the actions it was given", %{fixture: fixture} do
    %{"step" => %{"environment_steps" => [[]]}} = fixture

    {_observations, _pose, interface} =
      Interface.step(interface(), [%MoveForward{agent_id: "agent_id_0", distance: 0.05}])

    assert interface.env.actions == [["MoveForward"]]
  end

  test "a second step keeps stepping the same world", %{fixture: fixture} do
    %{"second step" => %{"observations" => monty_observations}} = fixture

    interface = interface()
    {_first, _pose, interface} = Interface.step(interface, [])
    {second, _pose, _interface} = Interface.step(interface, [])

    assert second["observations"] == monty_observations
  end

  test "an episode starts from a reset, which looks at the fresh world" do
    interface =
      Interface.new(
        env: %StubWorld{step: 0},
        reset: fn -> %StubWorld{step: 0} end,
        transforms: transforms()
      )

    {observations, _pose, _interface} = Interface.pre_episode(interface)

    assert observations["observations"] == ["after 1 steps", "first", "second"]
  end

  # -- the stub world and the tagging transforms ------------------------------

  defp interface do
    Interface.new(env: %StubWorld{step: 0}, transforms: transforms())
  end

  defp transforms do
    [%Tagging{name: "first"}, %Tagging{name: "second"}]
  end

  # What the transforms reported, in the order they ran.
  defp seen_by_the_transforms do
    receive do
      {:saw, name, saw, pose?, stream?} ->
        [{name, saw, pose?, stream?} | seen_by_the_transforms()]
    after
      0 -> []
    end
  end
end
