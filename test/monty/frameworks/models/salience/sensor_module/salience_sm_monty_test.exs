defmodule Monty.Frameworks.Models.Salience.SensorModule.SalienceSMMontyTest do
  @moduledoc """
  Monty's own cases for `SalienceSM`, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/sensor_module_test.py` it translates.

  ## What could not be translated, and why

  Monty's private class drives `_normalize_salience`, `_weight_salience` and
  `region_locations_on_object` directly. The port keeps them private — the
  module's own comment says the confidence facts are held *at the output*, which
  is where these cases are held too — so four cases have no entry point that is
  theirs alone, and they are listed here rather than dropped:

    * `test_normalize_salience_does_clips_uniform_salience_between_0_and_1` —
      reachable only through a step, whose dither makes every map non-flat, so
      the clipping branch is never the one that runs.
    * `test_normalize_salience_normalizes_empty_salience` — a view with no
      pixels never reaches a step; the empty answer is `[]` by construction.
    * `test_weight_salience_decays_randomizes_and_normalizes_salience_in_that_order`
      — the three steps are one private function, and the dither draws from the
      episode's stream, so no public call can pin the intermediates.
    * `test_region_locations_on_object_returns_correct_locations` — its claim is
      asserted in `test_segment_region_creates_region_locations_on_object`,
      which reads the same locations off the region the module proposes.

  The rest drive `step`, `propose_goals`, `propose_region` and `state_dict`, and
  are translated with Monty's own view: a 64 by 64 observation whose object is
  the middle ten-by-ten block.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.AttentionRegion
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.Salience.Strategies.Uniform
  alias Monty.Frameworks.Models.Salience.Telemetry.DetailedSalienceSMTelemetry
  alias Monty.Geometry.Rotation

  @sensor "test"
  @size 64
  @centre 32
  @radius 5

  defp on_object?(row, column) do
    row >= @centre - @radius and row < @centre + @radius and
      column >= @centre - @radius and column < @centre + @radius
  end

  defp rgba do
    for row <- 0..(@size - 1) do
      for column <- 0..(@size - 1) do
        [rem(row * 4, 255), rem(column * 6, 255), rem(row + column, 255), 255]
      end
    end
  end

  defp depth, do: List.duplicate(List.duplicate(1.0, @size), @size)

  defp semantic_3d do
    for row <- 0..(@size - 1), column <- 0..(@size - 1) do
      [row * 1.0, column * 1.0, 1.0, if(on_object?(row, column), do: 1.0, else: 0.0)]
    end
  end

  defp observation do
    %{"rgba" => rgba(), "depth" => depth(), "semantic_3d" => semantic_3d()}
  end

  defp on_object_locations do
    for row <- 0..(@size - 1), column <- 0..(@size - 1), on_object?(row, column) do
      [row * 1.0, column * 1.0, 1.0]
    end
  end

  defp rgb_of(observation) do
    Enum.map(observation["rgba"], fn row -> Enum.map(row, &Enum.take(&1, 3)) end)
  end

  defp agent_state do
    %AgentState{
      sensors: %{
        @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
      },
      position: [0.0, 0.0, 0.0],
      rotation: Rotation.identity()
    }
  end

  # The episode's stream, owned by this test: the dither draws from it, so the
  # numbers depend on the seed and nothing else.
  defp context, do: Monty.EpisodeStream.context(42)

  defp salience_module(options \\ []) do
    SalienceSM.new(
      @sensor,
      Keyword.merge(
        [telemetry: {DetailedSalienceSMTelemetry, DetailedSalienceSMTelemetry.new()}],
        options
      )
    )
  end

  # A step, with the state it needs already in place.
  defp step(sm, ctx, looked? \\ false) do
    sm = SalienceSM.update_state(agent_state(), sm)
    SalienceSM.step(observation(), looked?, ctx, sm)
  end

  defp goals_of(sm), do: sm |> SalienceSM.propose_goals() |> elem(0)

  # test_step_snapshots_telemetry
  test "a step records the view, the salience map and the goals" do
    ctx = context()
    {nil, sm} = step(salience_module(), ctx)

    recorded = SalienceSM.state_dict(sm)

    assert length(recorded.raw_observations) == 1
    assert length(recorded.salience_maps) == 1
    assert length(recorded.goals) == 1
    assert hd(recorded.goals) == goals_of(sm)

    # The map recorded is the strategy's answer for this view.
    assert hd(recorded.salience_maps) ==
             Uniform.call(Uniform.new(), ctx, observation()["rgba"], depth())
  end

  # test_step_returns_no_percept
  test "a step answers no percept: a salience module says where, not what" do
    assert {nil, _sm} = step(salience_module(), context())
  end

  # test_step_proposes_goals_properly
  test "there is one goal per on-object pixel, in the order the view collected them" do
    # Monty mocks the weighting so its case can pin each confidence; the port's
    # confidences come from the dithered weighting, so what is pinned here is
    # what the goal is made of: the pixel's place, the module as its sender, no
    # message to a learning module, and a confidence in the range a goal may use.
    {nil, sm} = step(salience_module(), context())

    goals = goals_of(sm)

    assert Enum.map(goals, & &1.location) == on_object_locations()

    for goal <- goals do
      assert goal.pass_message == false
      assert goal.process_features_in_lm == false
      assert goal.sender_id == @sensor
      assert goal.sender_type == :sm
      assert goal.confidence >= 0.0 and goal.confidence <= 1.0
    end
  end

  # test_segment_region_returns_empty_region_if_no_segmentation_strategy
  test "without a segmentation strategy there is no region to attend to" do
    {nil, sm} = step(salience_module(), context())

    assert sm |> SalienceSM.propose_region() |> elem(0) |> AttentionRegion.empty?()
  end

  # test_segment_region_creates_segmentation_map
  test "the segmentation map the strategy answered is recorded" do
    ctx = context()
    {nil, sm} = step(segmented_module(), ctx)

    recorded = SalienceSM.state_dict(sm)

    {mask, _strategy} = SlicMerge.call(SlicMerge.new(n_seeds: 4), ctx, rgb_of(observation()))

    assert hd(recorded.segmentation_maps) == mask
  end

  # test_segment_region_creates_region_locations_on_object
  test "the region is the pixels both segmented and on the object" do
    ctx = context()
    {nil, sm} = step(segmented_module(), ctx)

    {region, _sm} = SalienceSM.propose_region(sm)

    {mask, _strategy} = SlicMerge.call(SlicMerge.new(n_seeds: 4), ctx, rgb_of(observation()))

    expected =
      for row <- 0..(@size - 1),
          column <- 0..(@size - 1),
          on_object?(row, column),
          Enum.at(Enum.at(mask, row), column) != 0,
          do: [row * 1.0, column * 1.0, 1.0]

    assert region.locations == expected
    refute AttentionRegion.empty?(region)
  end

  # test_segment_region_creates_uniformly_weighted_attention_region
  test "every pixel of the region is attended to equally" do
    {nil, sm} = step(segmented_module(), context())

    {region, _sm} = SalienceSM.propose_region(sm)

    assert length(region.weights) == length(region.locations)
    assert Enum.all?(region.weights, &(&1 == AttentionRegion.max_weight()))
  end

  # test_step_segments_region_and_stores_it_for_propose_region
  test "the step stores its region, so the next caller is offered it" do
    empty = salience_module()
    {empty_region, _sm} = SalienceSM.propose_region(empty)

    {nil, sm} = step(segmented_module(), context())
    {region, _sm} = SalienceSM.propose_region(sm)
    {again, _sm} = SalienceSM.propose_region(sm)

    assert AttentionRegion.empty?(empty_region)
    refute AttentionRegion.empty?(region)
    assert again == region
  end

  defp segmented_module do
    salience_module(segmentation_strategy: {SlicMerge, SlicMerge.new(n_seeds: 4)})
  end
end
