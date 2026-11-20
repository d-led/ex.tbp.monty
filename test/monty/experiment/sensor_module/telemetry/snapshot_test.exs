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

  # The telemetry an earlier step left, in the order the transform keeps it:
  # newest first, which is what makes recording one observation constant-time
  # instead of a copy of everything the sensor has already seen. What a reader
  # gets back has the order Monty's list has (`reported/1`).
  @kept Enum.reverse(@observations)

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
    {payload, snapshot} = Snapshot.call(Snapshot.new(), ctx(), payload(:observed_once, %{}))

    {payload, _snapshot} =
      Snapshot.call(snapshot, ctx(), payload(@new_observation, payload.telemetry))

    assert reported(payload.telemetry)["raw_observations"] == [:observed_once, @new_observation]
  end

  # Monty appends to a list it keeps oldest first. The port grows the list at the
  # front, because appending copied everything the sensor had already seen on
  # every step — and the same term answered at the end would then not be the
  # list that is there.
  test "recording an observation does not copy the ones it already holds" do
    # Built at run time: the question is whether the list that was there is the
    # list that is still there, which a literal in the code cannot answer.
    held = for id <- @observations, do: id

    {payload, _snapshot} =
      Snapshot.call(
        Snapshot.new(),
        ctx(),
        payload(@new_observation, %{"raw_observations" => held})
      )

    assert :erts_debug.same(tl(payload.telemetry["raw_observations"]), held)
  end

  # test_reset_clears_previous_payload_telemetry_raw_observations
  test "after a reset the telemetry holds the observation that followed it alone" do
    telemetry = %{"raw_observations" => @kept}
    snapshot = Snapshot.new() |> Snapshot.reset()

    {payload, _snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, telemetry))

    assert reported(payload.telemetry)["raw_observations"] == [@new_observation]
  end

  # test_appends_sm_rotation_and_location_to_telemetry_sm_properties
  test "the sensor's pose joins the ones already in the telemetry" do
    telemetry = %{"sm_properties" => [%{"sm_rotation" => [1.0, 0.0, 0.0, 0.0]}]}
    snapshot = Snapshot.new()

    {payload, _snapshot} = Snapshot.call(snapshot, ctx(), payload(@new_observation, telemetry))

    reported = reported(payload.telemetry)

    assert length(reported["sm_properties"]) == 2
    assert Enum.any?(reported["sm_properties"], &(&1 == pose_property()))
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

    reported = reported(payload.telemetry)

    assert reported["raw_observations"] == [@new_observation, :observed_again]
    assert length(reported["sm_properties"]) == 2
  end

  # A frame, shaped like the ones a view finder measures: nested lists of floats
  # are what the world hands a sensor, and what a term of them costs. The numbers
  # are drawn rather than written, so the lists are built at run time like a
  # world's are — a literal frame of one repeated float is shared and measures as
  # a handful of words.
  defp frame do
    :rand.seed(:exsss, {1, 2, 3})

    %{
      "depth" => for(_row <- 1..64, do: for(_pixel <- 1..64, do: :rand.uniform())),
      "cam_to_world" => for(_row <- 1..4, do: for(_column <- 1..4, do: :rand.uniform()))
    }
  end

  test "a frame comes back exactly as it was measured" do
    {payload, _snapshot} = Snapshot.call(Snapshot.new(), ctx(), payload(frame(), %{}))

    assert reported(payload.telemetry)["raw_observations"] == [frame()]
  end

  # What is kept is a thousand frames, so the encoding is the point: as a term a
  # frame is seven times the heap it needs as a binary (§2.40).
  test "a frame is kept at a fraction of the heap the term takes" do
    observation = frame()

    {payload, _snapshot} = Snapshot.call(Snapshot.new(), ctx(), payload(observation, %{}))

    [kept] = payload.telemetry["raw_observations"]
    heap_bytes = :erts_debug.size(observation) * :erlang.system_info(:wordsize)

    assert byte_size(kept) * 3 < heap_bytes
  end

  # The question a run of the image world asked the hard way: keeping an episode
  # of frames costs the frames, not their square. Appending at the end of the
  # list copied everything the sensor had already seen on every step, which at
  # fifty steps of a 640 × 480 observation is gigabytes of garbage for one step
  # (§2.40, §2.41).
  test "an episode of frames costs the frames, not their square" do
    steps = 200
    observation = frame()

    telemetry =
      Enum.reduce(1..steps, %{}, fn _step, telemetry ->
        {payload, _snapshot} =
          Snapshot.call(Snapshot.new(), ctx(), payload(observation, telemetry))

        payload.telemetry
      end)

    kept = Enum.map(telemetry["raw_observations"], &byte_size/1) |> Enum.sum()
    heap_bytes = :erts_debug.size(telemetry) * :erlang.system_info(:wordsize)

    assert length(telemetry["raw_observations"]) == steps
    # The heap holds the list and the binaries' headers; the frames themselves
    # are the `kept` bytes. Anything near a square — `steps × kept` — is the copy
    # coming back.
    assert heap_bytes < 2 * kept
  end

  # What a logger reads: the telemetry in the order it was taken, which is the
  # order Monty's `state_dict` holds.
  defp reported(telemetry), do: Snapshot.state_dict(Snapshot.new(), telemetry)

  defp pose_property do
    %{"sm_rotation" => Tuple.to_list(@pose.rotation.wxyz), "sm_location" => @pose.position}
  end
end
