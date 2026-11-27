defmodule Monty.Simulators.ExMujoco.AgentActionsTest do
  @moduledoc """
  Translations of Monty's `tests/unit/simulators/mujoco/agent_actions_test.py`.

  Monty builds one `MuJoCoSimulator` per agent class and steps one action at a
  time into it, reading back `sim.states` — the agent's place, its `wxyz`
  rotation, and each sensor's pose relative to it. This port's `Simulator.step/3`
  answers the same shape, so a case here builds the same world (`Simulator`), the
  same one patch sensor of the default resolution, and reads the same fields.

  Three shapes of the Python differ, and each case says which it is:

  - **The class under test.** Monty's suite is `@parameterized_class`-ed over
    `DistantAgent` and `SurfaceAgent`, and `skip_on_missing_actuate` skips the
    cases whose action a class does not have. Here the vocabulary is the same
    split (`Monty.Simulators.ExMujoco.Agent.perform/4`), so each case drives the
    classes that have the action and names them in its fixtures.
  - **The generators.** Monty's arguments come from Hypothesis; a case here is one
    run, over fixed values that sit at the ends and the middle of the same
    ranges — `distance` in metres, angles in degrees, `direction` from an angle in
    radians, and the constrained head cases from `(angle, constraint)` with
    `|angle| ≤ constraint`.
  - **The comparison.** Monty compares rotations with `Rotation.approx_equal`,
    whose tolerance is `1e-6` radians and which treats a quaternion and its
    negative as one rotation — MuJoCo answers with the negative of what went in
    for some heads, which `test_set_sensor_rotation` says out loud. So
    `assert_same_rotation/2` compares the same way, and `assert_same_position/2`
    uses Monty's `DEFAULT_TOLERANCE` of `1e-6` metres.

  Monty's `sim_reset` and `setUpClass`/`tearDown` exist because Hypothesis reruns
  a case inside one mutable simulator. A step here is a function of the simulator
  value it is given, so the simulator built once per class is already at the pose
  the episode starts with, and a case that steps twice says so by stepping twice.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Actions.{
    ActionJSONEncoder,
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPose,
    SetSensorRotation,
    TurnLeft,
    TurnRight
  }

  alias Monty.Simulators.ExMujoco.{Orientation, Simulator}

  @agent_id "agent_id_0"
  @sensor_id "sensor_id_0"

  # The two classes Monty's suite runs over, and the two whose vocabularies this
  # port splits the same way.
  @distant "DistantAgent"
  @surface "SurfaceAgent"

  # Monty's `DEFAULT_TOLERANCE` and `ROTATION_TOLERANCE_RADIANS`.
  @tolerance 1.0e-6

  # Monty's `DEFAULT_RESOLUTION`: the patch sensor every case looks through.
  @resolution 64

  setup_all do
    %{simulators: Map.new([@distant, @surface], &{&1, simulator(&1)})}
  end

  describe "a pose set outright" do
    # test_set_agent_pose
    test "is where the agent then stands, facing the way it was given", %{
      simulators: simulators
    } do
      poses = [
        {[0.0, 0.0, 0.0], {1.0, 0.0, 0.0, 0.0}},
        {[1.0, 1.5, 0.1], {0.7071067811865475, 0.7071067811865475, 0.0, 0.0}},
        {[-2.5, 0.25, 3.0], {-0.5, 0.5, -0.5, 0.5}}
      ]

      for class <- [@distant, @surface], {location, rotation} <- poses do
        state =
          step!(simulators[class], [
            %SetAgentPose{agent_id: @agent_id, location: location, rotation_quat: rotation}
          ])

        assert_same_position(agent_position(state), location)
        assert_same_rotation(agent_rotation(state), rotation)
      end
    end
  end

  describe "a sensor's rotation" do
    # test_set_sensor_rotation
    test "turns the head by the given angles, and never moves the sensor", %{
      simulators: simulators
    } do
      # An x rotation of 229°, which is 131° the other way and arrives as its
      # negative: Monty's `@example`, quoted here so the case still says which
      # quaternions a head may be handed.
      angles = [0.0, 45.0, 90.0, 180.0, 270.0, 359.0]

      quaternions =
        Enum.map(angles, &Orientation.about_x/1) ++
          [{-0.4161468365471424, 0.9092974268256817, 0.0, 0.0}]

      for class <- [@distant, @surface], quaternion <- quaternions do
        state =
          step!(simulators[class], [
            %SetSensorRotation{agent_id: @agent_id, rotation_quat: quaternion}
          ])

        assert_same_position(sensor(state)["position"], [0.0, 0.0, 0.0])
        assert_same_rotation(sensor(state)["rotation"], quaternion)
      end
    end
  end

  describe "a step forward" do
    # test_move_forward
    test "goes in the agent's own forward direction, which is the negative z axis", %{
      simulators: simulators
    } do
      for class <- [@distant, @surface], distance <- [0.0, 0.5, 2.5, 10.0] do
        state = step!(simulators[class], [%MoveForward{agent_id: @agent_id, distance: distance}])

        assert_same_position(agent_position(state), [0.0, 0.0, -distance])
      end
    end
  end

  describe "a turn" do
    # test_turn_right
    test "about the vertical is the frame's clockwise yaw", %{simulators: simulators} do
      for degrees <- [-180.0, -90.0, -45.0, 0.0, 30.0, 90.0, 135.0, 180.0] do
        state =
          step!(simulators[@distant], [
            %TurnRight{agent_id: @agent_id, rotation_degrees: degrees}
          ])

        assert_same_rotation(agent_rotation(state), Orientation.about_y(-degrees))
      end
    end

    # test_turn_left
    test "the other way is the frame's anticlockwise yaw", %{simulators: simulators} do
      for degrees <- [-180.0, -90.0, -45.0, 0.0, 30.0, 90.0, 135.0, 180.0] do
        state =
          step!(simulators[@distant], [
            %TurnLeft{agent_id: @agent_id, rotation_degrees: degrees}
          ])

        assert_same_rotation(agent_rotation(state), Orientation.about_y(degrees))
      end
    end
  end

  describe "the head's pitch" do
    # test_look_up
    test "is the angle asked for, while the constraint leaves room for it", %{
      simulators: simulators
    } do
      for {angle, constraint} <- [{-45.0, 45.0}, {0.0, 0.0}, {30.0, 90.0}, {180.0, 180.0}] do
        state =
          step!(simulators[@distant], [
            %LookUp{agent_id: @agent_id, rotation_degrees: angle, constraint_degrees: constraint}
          ])

        assert_same_rotation(sensor(state)["rotation"], Orientation.about_x(angle))
      end
    end

    # test_look_down
    test "goes the other way, and stops at the same constraint", %{simulators: simulators} do
      for {angle, constraint} <- [{-45.0, 45.0}, {0.0, 0.0}, {30.0, 90.0}, {180.0, 180.0}] do
        state =
          step!(simulators[@distant], [
            %LookDown{
              agent_id: @agent_id,
              rotation_degrees: angle,
              constraint_degrees: constraint
            }
          ])

        assert_same_rotation(sensor(state)["rotation"], Orientation.about_x(-angle))
      end
    end

    # test_multiple_look_up_constrained
    test "accumulates over two actions, but never past the constraint", %{simulators: simulators} do
      for {first, second, constraint} <- [
            {60.0, 60.0, 90.0},
            {-45.0, -45.0, 90.0},
            {120.0, 120.0, 30.0},
            {-20.0, 10.0, 45.0}
          ] do
        state =
          step!(simulators[@distant], [
            %LookUp{agent_id: @agent_id, rotation_degrees: first, constraint_degrees: constraint},
            %LookUp{agent_id: @agent_id, rotation_degrees: second, constraint_degrees: constraint}
          ])

        assert abs(pitch(state)) <= constraint + @tolerance
      end
    end

    # test_multiple_look_down_constrained
    test "and the same two ways down", %{simulators: simulators} do
      for {first, second, constraint} <- [
            {60.0, 60.0, 90.0},
            {-45.0, -45.0, 90.0},
            {120.0, 120.0, 30.0},
            {-20.0, 10.0, 45.0}
          ] do
        state =
          step!(simulators[@distant], [
            %LookDown{
              agent_id: @agent_id,
              rotation_degrees: first,
              constraint_degrees: constraint
            },
            %LookDown{
              agent_id: @agent_id,
              rotation_degrees: second,
              constraint_degrees: constraint
            }
          ])

        assert abs(pitch(state)) <= constraint + @tolerance
      end
    end
  end

  describe "an orbit, then a step forward" do
    # test_orient_horizontal
    test "keeps to the XZ plane and obeys the law of cosines", %{simulators: simulators} do
      for {degrees, left, forward} <- [
            {0.0, 0.0, 0.0},
            {0.0, 2.5, 4.0},
            {90.0, 0.0, 1.0},
            {-90.0, 3.0, 0.0},
            {45.0, 1.0, 2.0},
            {180.0, 2.0, 3.0},
            {-135.0, 0.5, 4.0}
          ] do
        state =
          step!(simulators[@surface], [
            %OrientHorizontal{
              agent_id: @agent_id,
              rotation_degrees: degrees,
              left_distance: left,
              forward_distance: forward
            }
          ])

        # The action is a move left, then a yaw, then the forward part of the
        # orbit — Monty's `orient_horizontal_position/3`, in the same order.
        radians = degrees * :math.pi() / 180.0
        expected = [-left + forward * :math.sin(radians), 0.0, -forward * :math.cos(radians)]

        assert_same_rotation(agent_rotation(state), Orientation.about_y(-degrees))
        assert_same_position(agent_position(state), expected)
        # The agent does not leave the plane an orbit is made in…
        assert Enum.at(agent_position(state), 1) == 0.0
        # …and the distance it ends up from where it started is the law of
        # cosines' answer for the two legs it stepped.
        assert_same_distance(
          distance_from_origin(state),
          law_of_cosines(left, forward, 90.0 - degrees)
        )
      end
    end

    # test_orient_vertical
    test "keeps to the YZ plane and obeys it too", %{simulators: simulators} do
      for {degrees, down, forward} <- [
            {0.0, 0.0, 0.0},
            {0.0, 2.5, 4.0},
            {90.0, 0.0, 1.0},
            {-90.0, 3.0, 0.0},
            {45.0, 1.0, 2.0},
            {180.0, 2.0, 3.0},
            {-135.0, 0.5, 4.0}
          ] do
        state =
          step!(simulators[@surface], [
            %OrientVertical{
              agent_id: @agent_id,
              rotation_degrees: degrees,
              down_distance: down,
              forward_distance: forward
            }
          ])

        radians = degrees * :math.pi() / 180.0
        expected = [0.0, -down + forward * :math.sin(radians), -forward * :math.cos(radians)]

        assert_same_rotation(agent_rotation(state), Orientation.about_x(degrees))
        assert_same_position(agent_position(state), expected)
        assert Enum.at(agent_position(state), 0) == 0.0

        assert_same_distance(
          distance_from_origin(state),
          law_of_cosines(down, forward, 90.0 - degrees)
        )
      end
    end
  end

  describe "a move across the surface" do
    # test_move_tangentially
    test "goes along the direction it is given, in the world, without turning", %{
      simulators: simulators
    } do
      for {degrees, distance} <- [
            {-180.0, 1.0},
            {-90.0, 3.0},
            {0.0, 0.5},
            {45.0, 0.0},
            {90.0, 10.0},
            {180.0, 2.5}
          ] do
        direction = tangential_direction(degrees)
        state = tangent!(simulators[@surface], distance, direction)

        assert_same_position(agent_position(state), scale(direction, distance))
        assert_same_rotation(agent_rotation(state), Orientation.identity())
      end
    end

    # test_move_tangentially_obeys_inverse_property
    test "and its inverse undoes it, whichever of the two values is negated", %{
      simulators: simulators
    } do
      for {degrees, distance} <- [{-180.0, 0.0}, {-45.0, 2.0}, {0.0, 4.0}, {75.0, 1.5}],
          invert_vector <- [true, false] do
        direction = tangential_direction(degrees)

        # Only one of the two values may be negated for the move to be undone.
        {inverse_distance, inverse_direction} =
          if invert_vector,
            do: {distance, scale(direction, -1.0)},
            else: {-distance, direction}

        state =
          step!(simulators[@surface], [
            %MoveTangentially{agent_id: @agent_id, distance: distance, direction: direction},
            %MoveTangentially{
              agent_id: @agent_id,
              distance: inverse_distance,
              direction: inverse_direction
            }
          ])

        assert_same_rotation(agent_rotation(state), Orientation.identity())
        assert_same_position(agent_position(state), [0.0, 0.0, 0.0])
      end
    end

    # test_move_tangentially_from_rotated_agent
    test "reads the direction in the world even when the agent is turned", %{
      simulators: simulators
    } do
      # A direction is world-side, so a policy turns its own heading by the
      # agent's rotation before it asks (Monty's case does the same).
      rotations = [
        {1.0, 0.0, 0.0, 0.0},
        Orientation.about_y(90.0),
        Orientation.about_x(45.0),
        Orientation.multiply(Orientation.about_y(30.0), Orientation.about_x(-60.0))
      ]

      for rotation <- rotations, degrees <- [-90.0, 0.0, 30.0, 135.0], distance <- [0.0, 2.0] do
        direction = Orientation.rotate(rotation, tangential_direction(degrees))

        {turned, _posed} =
          run(simulators[@surface], [
            %SetAgentPose{agent_id: @agent_id, location: [0.0, 0.0, 0.0], rotation_quat: rotation}
          ])

        state =
          turned
          |> run([
            %MoveTangentially{agent_id: @agent_id, distance: distance, direction: direction}
          ])
          |> elem(1)

        assert_same_position(agent_position(state), scale(direction, distance))
        assert_same_rotation(agent_rotation(state), rotation)
      end
    end
  end

  # -- a world, and the actions stepped into it -----------------------------

  # Monty's `setUpClass`: one simulator per agent class, holding one agent with
  # one patch sensor of the default resolution, and no objects — the agent is
  # what the case moves.
  defp simulator(class) do
    Simulator.start(%{
      "agents" => [
        %{
          "agent_id" => @agent_id,
          "class" => class,
          "sensor_configs" => %{@sensor_id => sensor()}
        }
      ]
    })
  end

  defp sensor do
    %{
      "width" => @resolution,
      "height" => @resolution,
      "zoom" => 1.0,
      "position" => [0.0, 0.0, 0.0],
      "rotation" => [1.0, 0.0, 0.0, 0.0]
    }
  end

  # Monty's `sim.step([action])`, with the sensors rendering nothing: a case here
  # reads where the agents are, and the images are the renderer's own cases.
  # The simulator a step answers is the one the next step takes, which is how a
  # case that turns the agent and then moves it keeps the turn.
  defp run(simulator, actions) do
    encoded = Enum.map(actions, &ActionJSONEncoder.encode/1)

    {simulator, _seen, state} = Simulator.step(simulator, encoded, [])
    {simulator, Map.fetch!(state, @agent_id)}
  end

  defp step!(simulator, actions), do: simulator |> run(actions) |> elem(1)

  defp tangent!(simulator, distance, direction),
    do:
      step!(simulator, [
        %MoveTangentially{agent_id: @agent_id, distance: distance, direction: direction}
      ])

  # The heading Monty's case builds, offset and all: its `MoveTangentially`
  # direction for an angle is `(cos θ − π/2, sin θ + π/2, 0)`.
  defp tangential_direction(degrees) do
    radians = degrees * :math.pi() / 180.0
    offset = :math.pi() / 2.0

    [:math.cos(radians - offset), :math.sin(radians + offset), 0.0]
  end

  # -- what a step answered ------------------------------------------------

  defp agent_position(state), do: state["position"]

  defp agent_rotation(state), do: state["rotation"]

  defp sensor(state), do: Map.fetch!(state["sensors"], @sensor_id)

  # The head's pitch in degrees, as Monty reads it off the sensor's rotation
  # with `as_euler("xyz")`.
  defp pitch(state) do
    state
    |> sensor()
    |> Map.fetch!("rotation")
    |> List.to_tuple()
    |> Orientation.euler_x()
    |> degrees()
  end

  defp degrees(radians), do: radians * 180.0 / :math.pi()

  defp distance_from_origin(state) do
    [x, y, z] = agent_position(state)
    :math.sqrt(x * x + y * y + z * z)
  end

  # Monty's `np.sqrt(a² + b² − 2ab·cos θ)` on two legs of an orbit.
  defp law_of_cosines(a, b, between_degrees) do
    radians = between_degrees * :math.pi() / 180.0
    :math.sqrt(a * a + b * b - 2.0 * a * b * :math.cos(radians))
  end

  # -- what Monty compares with --------------------------------------------

  defp assert_same_position(actual, expected) do
    for {mine, theirs} <- Enum.zip(actual, expected) do
      assert_in_delta mine, theirs, @tolerance
    end
  end

  defp assert_same_distance(actual, expected), do: assert_in_delta(actual, expected, @tolerance)

  # `Rotation.approx_equal`: the angle between two rotations is at most `1e-6`
  # radians, which is the same statement as their normalised quaternions' dot
  # product being at least `cos(tol / 2)` — a quaternion and its negative being
  # one rotation, as they must.
  defp assert_same_rotation(actual, expected) do
    assert abs(dot(normalise(actual), normalise(expected))) >= :math.cos(@tolerance / 2.0),
           "expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp dot({aw, ax, ay, az}, {bw, bx, by, bz}), do: aw * bw + ax * bx + ay * by + az * bz

  # A rotation arrives as a list from `Simulator.state/1` and as a `wxyz` tuple
  # from `Orientation`; both are one rotation here.
  defp normalise(quaternion) do
    [w, x, y, z] =
      case quaternion do
        {a, b, c, d} -> [a, b, c, d]
        [a, b, c, d] -> [a * 1.0, b * 1.0, c * 1.0, d * 1.0]
      end

    length = :math.sqrt(w * w + x * x + y * y + z * z)

    {w / length, x / length, y / length, z / length}
  end

  defp scale(vector, factor), do: Enum.map(vector, &(&1 * factor))
end
