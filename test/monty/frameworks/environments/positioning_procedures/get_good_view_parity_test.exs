defmodule Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewParityTest do
  @moduledoc """
  The positioning procedure decides what Monty's decides, before a single step.

  `scripts/record_monty_positioning.py` ran Monty's own `GetGoodView` over
  sixteen-by-sixteen semantic images and wrote down every answer it gave: how much
  of the view is on the object, which pixel it aimed at, the two rotations that
  aim there, and the whole state machine over two scripted episodes — move, move,
  turn, done, and the extra turn a two-object scene asks for first.

  ## What this pins that a behavioural test cannot

  The pixel it aims at is the maximum of a smoothed on-object mask, and the
  smoothing is `scipy.ndimage.gaussian_filter(image, size // 16, mode="constant")`
  — a *different* Gaussian from the one the salience code uses: scipy truncates at
  four sigma and pads with zeros, OpenCV at eight and reflects. The recorded
  location is the only thing that can catch a radius, a normalisation or a padding
  that is off.

  ## Poses

  States are recorded as quaternions, not Euler angles: what is compared is
  `compute_look_amounts`, not two ways of reading a pose.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.MoveForward
  alias Monty.Frameworks.Environments.PositioningProcedures
  alias Monty.Frameworks.Environments.PositioningProcedures.GetGoodView
  alias Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewFactory
  alias Monty.Frameworks.Environments.PositioningProcedures.ObjectNotVisibleError
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.Rotation

  @fixture Path.expand("../../../../fixtures/monty_positioning.json", __DIR__)

  # Degrees for rotations, metres for locations; the recording is float64
  # arithmetic on float64 input.
  @degrees 1.0e-9
  @metres 1.0e-12

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "how much of the view is on an object is Monty's", %{fixture: fixture} do
    image = fixture["images"]["two objects"]

    assert_in_delta PositioningProcedures.get_perc_on_obj_semantic(image, :any),
                    fixture["percentages"]["any object"],
                    @metres

    assert_in_delta PositioningProcedures.get_perc_on_obj_semantic(image, 3),
                    fixture["percentages"]["target only"],
                    @metres
  end

  test "the turn and the pitch are Monty's", %{fixture: fixture} do
    for %{"relative_location" => location, "state" => pose} = recorded <-
          fixture["look_amounts"] do
      {down, left} =
        GetGoodView.compute_look_amounts(procedure(fixture), location, state(pose))

      assert_in_delta down, recorded["down_degrees"], @degrees, "down for #{inspect(location)}"
      assert_in_delta left, recorded["left_degrees"], @degrees, "left for #{inspect(location)}"
    end
  end

  test "it looks at the pixel Monty looked at", %{fixture: fixture} do
    location =
      GetGoodView.find_location_to_look_at(
        procedure(fixture),
        observation(fixture, "small", 1.0),
        state(fixture["default_state"])
      )

    location
    |> Enum.zip(fixture["location_to_look_at"])
    |> Enum.each(fn {got, want} -> assert_in_delta got, want, @metres end)
  end

  test "the centre pixel decides whether the sensor is on the object", %{fixture: fixture} do
    %{"on object" => on_object, "off object" => off_object} = fixture["is_on_target_object"]

    assert GetGoodView.on_target_object?(procedure(fixture), observation(fixture, "centred", 1.0)) ==
             on_object

    assert GetGoodView.on_target_object?(procedure(fixture), observation(fixture, "corner", 1.0)) ==
             off_object
  end

  test "it moves only when the object is neither big enough nor close enough", %{fixture: fixture} do
    closer = fixture["moving_closer"]

    assert move(procedure(fixture), fixture, "big", 1.0) ==
             expected_move(closer["close enough by percentage"])

    assert move(procedure(fixture), fixture, "small", 0.02) ==
             expected_move(closer["close enough by distance"])

    assert move(procedure(fixture), fixture, "small", 1.0) ==
             expected_move(closer["still far away"])
  end

  test "a target that is not in a multi-object view stops it moving", %{fixture: fixture} do
    procedure = procedure(fixture, multiple_objects_present: true)

    assert move(procedure, fixture, "other object", 2.0) ==
             expected_move(fixture["moving_closer"]["nothing visible"])
  end

  test "a single-object scene with nothing in it is a fault", %{fixture: fixture} do
    %{"no object at all" => %{"raises" => "ObjectNotVisibleError"}} = fixture["moving_closer"]

    assert_raise ObjectNotVisibleError, fn ->
      move(procedure(fixture), fixture, "empty", 2.0)
    end
  end

  test "the state machine ends where Monty's ends", %{fixture: fixture} do
    assert_episode(fixture, "single object", multiple_objects_present: false)
  end

  test "a two-object scene turns towards the target before it moves", %{fixture: fixture} do
    assert_episode(fixture, "two objects", multiple_objects_present: true)
  end

  test "the factory builds the procedure Monty's defaults describe", %{fixture: fixture} do
    factory =
      GetGoodViewFactory.new(agent_id: fixture["agent_id"], sensor_id: fixture["sensor_id"])

    procedure = GetGoodViewFactory.create(factory, fixture["target_semantic_id"])

    assert procedure.good_view_distance == fixture["good_view_distance"]
    assert procedure.good_view_percentage == fixture["good_view_percentage"]
    refute procedure.multiple_objects_present
    assert procedure.allow_translation
  end

  # -- replaying a recorded episode ------------------------------------------

  # The procedure is carried from step to step, so each answer is judged with the
  # state the earlier steps left behind — the state machine, not one call.
  defp assert_episode(fixture, name, options) do
    {answers, _procedure} =
      Enum.map_reduce(fixture["episodes"][name], procedure(fixture, options), fn step,
                                                                                 procedure ->
        {result, procedure} =
          GetGoodView.call(
            procedure,
            observation(fixture, step["image"], step["depth_on_object"]),
            state(fixture["default_state"])
          )

        {{step, result}, procedure}
      end)

    for {%{"step" => label} = step, result} <- answers do
      assert action_names(result.actions) == Enum.map(step["actions"], & &1["action"]), label
      assert result.success == step["success"], "#{label}: success"
      assert result.terminated == step["terminated"], "#{label}: terminated"
      assert result.truncated == step["truncated"], "#{label}: truncated"

      assert_actions(result.actions, step["actions"], label)
    end
  end

  defp assert_actions(actions, expected, label) do
    Enum.zip(actions, expected)
    |> Enum.each(fn {action, recorded} ->
      if recorded["rotation_degrees"] != nil do
        assert_in_delta action.rotation_degrees, recorded["rotation_degrees"], @degrees, label
      end

      if recorded["distance"] != nil do
        assert_in_delta action.distance, recorded["distance"], @metres, label
      end
    end)
  end

  # -- fixtures --------------------------------------------------------------

  defp procedure(fixture, options \\ []) do
    GetGoodView.new(
      agent_id: fixture["agent_id"],
      sensor_id: fixture["sensor_id"],
      target_semantic_id: fixture["target_semantic_id"],
      good_view_distance: fixture["good_view_distance"],
      good_view_percentage: fixture["good_view_percentage"],
      multiple_objects_present: Keyword.get(options, :multiple_objects_present, false)
    )
  end

  # An observation as Monty's positioning code reads it: a depth image per
  # sensor, and the point cloud flat, one row per pixel. Background pixels are
  # the far plane; object pixels take the depth the case is about.
  defp observation(fixture, image_name, depth_on_object) do
    image = fixture["images"][image_name]
    step = fixture["location_step"]
    background = fixture["background_depth"]

    pixels =
      image
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, row_index} ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {semantic_id, column_index} ->
          depth = if semantic_id == 0, do: background, else: depth_on_object
          {[column_index * step, row_index * step, -1.0, semantic_id * 1.0], depth}
        end)
      end)

    columns = length(hd(image))

    %{
      fixture["agent_id"] => %{
        fixture["sensor_id"] => %{
          "depth" =>
            pixels |> Enum.map(fn {_point, depth} -> depth end) |> Enum.chunk_every(columns),
          "semantic_3d" => Enum.map(pixels, fn {point, _depth} -> point end)
        }
      }
    }
  end

  defp state(%{
         "agent_position" => agent_position,
         "agent_rotation_wxyz" => agent_rotation,
         "sensor_position" => sensor_position,
         "sensor_rotation_wxyz" => sensor_rotation
       }) do
    %{
      "agent_id_0" => %AgentState{
        position: agent_position,
        rotation: rotation(agent_rotation),
        sensors: %{
          "view_finder" => %SensorState{
            position: sensor_position,
            rotation: rotation(sensor_rotation)
          }
        }
      }
    }
  end

  defp rotation(wxyz) do
    {:ok, rotation} = Rotation.from_quaternion(List.to_tuple(wxyz))
    rotation
  end

  # -- comparing what is left of a step --------------------------------------

  defp move(procedure, fixture, image, depth) do
    case GetGoodView.move_close_enough(procedure, observation(fixture, image, depth)) do
      nil -> nil
      %MoveForward{} = action -> {"MoveForward", action.distance}
    end
  end

  defp expected_move(%{"actions" => []}), do: nil

  defp expected_move(%{"actions" => [%{"action" => name, "distance" => distance}]}),
    do: {name, distance}

  defp action_names(actions) do
    Enum.map(actions, fn action -> action.__struct__ |> Module.split() |> List.last() end)
  end
end
