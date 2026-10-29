defmodule Monty.Frameworks.Models.Salience.SensorModule.SalienceSMParityTest do
  @moduledoc """
  The salience step, end to end, against Monty's own.

  `scripts/record_monty_salience_sm.py` stepped Monty's `SalienceSM` three times
  over a 32 by 32 view whose on-object pixels are a twelve by twelve blob, and
  wrote down what it proposed: where it wanted to look, how the return inhibitor
  weighted those pixels, and the scored values before the dither. These replay
  them through the whole chain — strategy, on-object reshape, inhibitor, weights
  — which is the one thing the per-piece parity tests cannot see.

  ## Why the confidences are compared with a bound, not a tolerance

  Monty dithers before it rescales, drawing from the run's random stream; this
  port draws from its own stream by design (`docs/monty-bugs.md` §2.1), so the
  two cannot produce the same confidences. The bound below is coarse on purpose
  and it is worth being plain about what it can see: it catches a module that
  scores the wrong pixels, forgets to rescale, or rescales the wrong way, and it
  cannot tell a decay factor of three quarters from one of two thirds, because
  the dither is the same size as that difference. Where Monty's answers *are*
  comparable — which pixels, in what order, with which scores and which
  inhibition — they are compared to a millionth.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.Salience.OnObjectObservation
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Vocus2SalienceConfig
  alias Monty.Geometry.Rotation

  @fixture Path.expand("../../../../../fixtures/monty_salience_sm.json", __DIR__)

  # Monty's maps are float32 and the inhibitor's weights are ratios of counts,
  # so this is as tight as the recording allows.
  @float32 1.0e-6

  # The dither is a twentieth of a unit and the rescale stretches the scores by
  # about two, so a confidence may sit this far from Monty's: five deviations.
  # Measured over this fixture the worst is 0.36.
  @dithered 0.5

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "the goals point at the pixels Monty chose, in its order", %{fixture: fixture} do
    for {%{"goal_locations" => monty}, module} <- Enum.zip(fixture["steps"], step(fixture)) do
      {goals, _module} = SalienceSM.propose_goals(module)
      assert Enum.map(goals, & &1.location) == monty
    end
  end

  test "the confidences follow Monty's scores, dithered and rescaled", %{fixture: fixture} do
    for {%{"decayed" => scores}, module} <- Enum.zip(fixture["steps"], step(fixture)) do
      {goals, _module} = SalienceSM.propose_goals(module)

      assert within(Enum.map(goals, & &1.confidence), rescale(scores), @dithered),
             "the confidences do not follow Monty's scores"
    end
  end

  test "the scores before the dither are Monty's", %{fixture: fixture} do
    for {%{"salience" => salience, "ior_weights" => ior}, index} <-
          Enum.with_index(fixture["steps"]) do
      assert within(view(fixture, index).salience, salience, @float32)
      assert within(weights(fixture, index), ior, @float32)
    end
  end

  # The inhibitor ages on every step, so its weights are the one thing that
  # tells a later step from an earlier one.
  test "a later step's inhibition differs from an earlier one's", %{fixture: fixture} do
    refute within(weights(fixture, 0), weights(fixture, 1), 1.0e-3),
           "the fixture is not exercising the inhibitor — every step looked the same way"
  end

  test "a module without a segmentation strategy proposes no region", %{fixture: fixture} do
    for module <- step(fixture) do
      {region, _module} = SalienceSM.propose_region(module)
      assert region.locations == []
    end
  end

  # -- replaying -------------------------------------------------------------

  # One module, stepped in Monty's order, answering every state it passed
  # through: the goals after the first step are not the goals after the third.
  defp step(fixture) do
    strategy = {Vocus2, strategy(fixture)}
    ctx = Context.new(0)

    {modules, _last} =
      Enum.map_reduce(
        Enum.with_index(fixture["steps"]),
        SalienceSM.update_state(
          agent(),
          SalienceSM.new("view_finder", salience_strategy: strategy)
        ),
        fn {_recorded, index}, module ->
          {nil, stepped} = SalienceSM.step(observation(fixture, index), false, ctx, module)
          {stepped, stepped}
        end
      )

    modules
  end

  # A module told where its sensor is, which is what a run does on every step.
  defp agent do
    %AgentState{
      position: [0.0, 0.0, 0.0],
      rotation: Rotation.identity(),
      sensors: %{
        "view_finder" => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
      }
    }
  end

  # Each step looks at a view whose blob and point cloud have moved, so the
  # inhibitor has somewhere new to suppress.
  defp observation(fixture, index), do: Enum.at(fixture["observations"], index)

  # The inhibitor's weights at step `index`: the same views, in order, scored the
  # same way and aged once per step.
  defp weights(fixture, index) do
    0..index
    |> Enum.reduce({nil, ReturnInhibitor.new()}, fn step, {_weights, inhibitor} ->
      view = view(fixture, step)
      ReturnInhibitor.call(inhibitor, view.centre_location, view.locations)
    end)
    |> elem(0)
  end

  defp view(fixture, index) do
    observation = observation(fixture, index)

    OnObjectObservation.from(
      observation,
      Vocus2.call(strategy(fixture), Context.new(0), observation["rgba"], observation["depth"])
    )
  end

  defp strategy(fixture) do
    config = fixture["strategy"]

    Vocus2.from_config(
      Vocus2SalienceConfig.new(
        center_sigma: config["center_sigma"],
        surround_sigma: config["surround_sigma"],
        n_scales: config["n_scales"],
        max_octaves: config["max_octaves"],
        use_depth: config["use_depth"],
        use_orientation: config["use_orientation"]
      )
    )
  end

  defp rescale(scores) do
    lowest = Enum.min(scores)
    scale = Enum.max(scores) - lowest
    Enum.map(scores, &((&1 - lowest) / scale))
  end

  defp within(actual, expected, tolerance) do
    length(actual) == length(expected) and
      actual
      |> Enum.zip(expected)
      |> Enum.all?(fn {got, want} -> abs(got - want) <= tolerance end)
  end
end
