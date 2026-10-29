defmodule Monty.Frameworks.Models.SensorModules.FeatureChangeFilterTest do
  @moduledoc """
  When a point is worth sending to a learning module.

  A surface agent takes hundreds of steps over one object. Without a filter every
  one of them would be a new point in a graph, so Monty's sensors carry
  `delta_thresholds`: send a point when a feature moved more than its tolerance,
  when the point moved far enough, or when enough steps have gone by without
  sending anything.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.SensorModules.FeatureChangeFilter
  alias Monty.Geometry.SurfacePoseVectors

  @thresholds %{
    "on_object" => 0,
    "n_steps" => 20,
    "hsv" => [0.1, 0.1, 0.1],
    "pose_vectors" => [:math.pi() / 4],
    "principal_curvatures_log" => [2, 2],
    "distance" => 0.01
  }

  defp percept(options) do
    {:ok, percept} =
      Message.new(
        Keyword.merge(
          [
            location: [0.0, 0.0, 0.1],
            morphological_features: %{
              "pose_vectors" =>
                SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
              "pose_fully_defined" => true,
              "on_object" => 1.0
            },
            non_morphological_features: %{
              "hsv" => [0.0, 1.0, 1.0],
              "principal_curvatures_log" => [-20.0, -20.0]
            },
            confidence: 1.0,
            pass_message: true,
            process_features_in_lm: true,
            sender_id: "patch",
            sender_type: :sm
          ],
          options
        )
      )

    percept
  end

  describe "the first point" do
    test "is always sent" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)
      percept = percept([])

      assert {sent, _memory} = FeatureChangeFilter.call(filter, percept, memory)
      assert sent.process_features_in_lm
    end
  end

  describe "a point that has barely moved" do
    test "is sent as a location only" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)

      {first, memory} = FeatureChangeFilter.call(filter, percept([]), memory)
      assert first.process_features_in_lm

      {second, _memory} =
        FeatureChangeFilter.call(filter, percept(location: [0.001, 0.0, 0.1]), memory)

      refute second.process_features_in_lm
    end

    test "and is sent again once it has moved far enough" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)

      {_first, memory} = FeatureChangeFilter.call(filter, percept([]), memory)

      {second, _memory} =
        FeatureChangeFilter.call(filter, percept(location: [0.02, 0.0, 0.1]), memory)

      assert second.process_features_in_lm
    end
  end

  describe "a feature that changed" do
    test "is sent when it moved past its own tolerance" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)
      {_first, memory} = FeatureChangeFilter.call(filter, percept([]), memory)

      # The same place, a different colour.
      changed =
        percept(
          non_morphological_features: %{
            "hsv" => [0.5, 1.0, 1.0],
            "principal_curvatures_log" => [-20.0, -20.0]
          }
        )

      assert {sent, _memory} = FeatureChangeFilter.call(filter, changed, memory)
      assert sent.process_features_in_lm
    end

    test "and held back when it did not" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)
      {_first, memory} = FeatureChangeFilter.call(filter, percept([]), memory)

      barely =
        percept(
          non_morphological_features: %{
            "hsv" => [0.05, 1.0, 1.0],
            "principal_curvatures_log" => [-20.0, -20.0]
          }
        )

      assert {held, _memory} = FeatureChangeFilter.call(filter, barely, memory)
      refute held.process_features_in_lm
    end

    test "and hue is measured the short way round the circle" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)

      {_first, memory} =
        FeatureChangeFilter.call(
          filter,
          percept(
            non_morphological_features: %{
              "hsv" => [0.99, 1.0, 1.0],
              "principal_curvatures_log" => [-20.0, -20.0]
            }
          ),
          memory
        )

      # A step from 0.99 to 0.01 is two hundredths, not ninety-eight.
      around_the_circle =
        percept(
          non_morphological_features: %{
            "hsv" => [0.01, 1.0, 1.0],
            "principal_curvatures_log" => [-20.0, -20.0]
          }
        )

      assert {held, _memory} = FeatureChangeFilter.call(filter, around_the_circle, memory)
      refute held.process_features_in_lm
    end
  end

  describe "a point that has not changed at all" do
    test "is sent anyway once enough steps have gone by" do
      thresholds = Map.put(@thresholds, "n_steps", 1)
      {filter, memory} = FeatureChangeFilter.new(thresholds)
      {_first, memory} = FeatureChangeFilter.call(filter, percept([]), memory)

      {_held, memory} = FeatureChangeFilter.call(filter, percept([]), memory)
      {sent, memory} = FeatureChangeFilter.call(filter, percept([]), memory)

      assert sent.process_features_in_lm

      # ... and the count starts again.
      {held_again, _memory} = FeatureChangeFilter.call(filter, percept([]), memory)
      refute held_again.process_features_in_lm
    end
  end

  describe "a percept the sensor already called uninteresting" do
    test "is passed on unchanged" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)

      uninteresting = percept(process_features_in_lm: false)

      assert {passed, _memory} = FeatureChangeFilter.call(filter, uninteresting, memory)
      refute passed.process_features_in_lm
    end

    test "and one that may not be passed on at all is left alone" do
      {filter, memory} = FeatureChangeFilter.new(@thresholds)

      withheld = percept(pass_message: false, process_features_in_lm: false)

      assert {passed, _memory} = FeatureChangeFilter.call(filter, withheld, memory)
      refute passed.pass_message
    end
  end
end
