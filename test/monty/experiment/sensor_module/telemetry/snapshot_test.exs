defmodule Monty.Experiment.SensorModules.Telemetry.SnapshotTest do
  @moduledoc """
  Translates `tests/unit/experiments/sensor_modules/telemetry_test.py`.

  Monty's cases are property-based over a list of distinct sentinels and a
  generated sensor pose; what each asserts is a count and a membership, so the
  fixtures here are a short list of distinct atoms and one pose. The pose case
  compares with `np.allclose` because Monty's sensor state is numpy; the port's
  numbers are exact copies, so they are compared exactly.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.SensorModules.Telemetry.Snapshot
  alias Monty.Geometry.Rotation
  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  @observations [:observed_once, :observed_twice, :observed_thrice]
  @new_observation :just_observed

  @pose %{position: [0.25, -1.5, 2.0], rotation: %Rotation{wxyz: {0.5, 0.5, 0.5, 0.5}}}

  defp payload(observation, telemetry) do
    %Payload{observation: observation, percept: nil, goals: [], region: nil, telemetry: telemetry}
  end

  defp ctx do
    %TransformContext{
      sensor_state: %{position: @pose.position, rotation: @pose.rotation}
    }
  end

  # test_appends_observation_to_telemetry_raw_observations
  test "the observation joins the ones already in the telemetry" do
    telemetry = %{"raw_observations" => @observations}
    snapshot = Snapshot.new()

    {payload, _snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, telemetry))

    assert payload.telemetry["raw_observations"] == @observations ++ [@new_observation]
  end

  # test_reset_clears_previous_payload_telemetry_raw_observations
  test "after a reset the telemetry holds the observation that followed it alone" do
    telemetry = %{"raw_observations" => @observations}
    snapshot = Snapshot.new() |> Snapshot.reset()

    {payload, _snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, telemetry))

    assert payload.telemetry["raw_observations"] == [@new_observation]
  end

  # test_appends_sm_rotation_and_location_to_telemetry_sm_properties
  test "the sensor's pose joins the ones already in the telemetry" do
    telemetry = %{"sm_properties" => [%{"sm_rotation" => [1.0, 0.0, 0.0, 0.0]}]}
    snapshot = Snapshot.new()

    {payload, _snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, telemetry))

    assert length(payload.telemetry["sm_properties"]) == 2

    assert Enum.any?(payload.telemetry["sm_properties"], &(&1 == pose_property()))
  end

  # test_reset_clears_previous_payload_telemetry_sm_properties
  test "after a reset the telemetry holds the pose that followed it alone" do
    telemetry = %{"sm_properties" => [%{"sm_rotation" => [1.0, 0.0, 0.0, 0.0]}]}
    snapshot = Snapshot.new() |> Snapshot.reset()

    {payload, _snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, telemetry))

    assert payload.telemetry["sm_properties"] == [pose_property()]
  end

  # The reset flag is spent by the step it applied to: Monty sets `_reset = False`
  # inside `__call__`, so the step after that one appends rather than clears.
  test "the next step after a reset appends to what the reset started" do
    snapshot = Snapshot.new() |> Snapshot.reset()

    {payload, snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, %{}))

    {payload, _snapshot} =
      Snapshot.call(snapshot, ctx(), payload(:observed_again, payload.telemetry))

    assert payload.telemetry["raw_observations"] == [@new_observation, :observed_again]
    assert length(payload.telemetry["sm_properties"]) == 2
  end

  defp pose_property do
    %{"sm_rotation" => Tuple.to_list(@pose.rotation.wxyz), "sm_location" => @pose.position}
  end
end
