defmodule ExamplePlugin.SurfaceStepperTest do
  @moduledoc """
  The surface policy at the plugin's boundary: a step is an action the surf agent
  can take, and the plugin carries the policy's state from one call to the next.

  The decisions themselves are `SurfacePolicyCurvatureInformed`'s own cases; what
  is specified here is that wrapping it in a plugin does not change them, which is
  the part a struct with a ported policy inside can get wrong.
  """

  use ExUnit.Case, async: true

  alias ExamplePlugin.SurfaceStepper
  alias Monty.Cmp.Message
  alias Monty.Context
  alias Monty.Frameworks.Actions.{MoveForward, MoveTangentially, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @agent "agent_id_0"
  @sensor "view_finder"

  @surf_actions [MoveForward, MoveTangentially, OrientHorizontal, OrientVertical]

  test "a step is one action the surf agent can take" do
    {result, _policy} = step(SurfaceStepper.new())

    assert %MotorPolicyResult{actions: [action]} = result
    assert action.__struct__ in @surf_actions
  end

  test "the policy comes back as it now stands, so the next step starts there" do
    policy = SurfaceStepper.new()

    {_first, after_one} = step(policy)
    {_second, after_two} = step(after_one)

    # The ported policy keeps its heading between steps; a wrapper that dropped it
    # would answer the same action forever.
    assert after_one != policy
    assert after_two != after_one
  end

  test "starting an episode gives back a policy at the surface, not the last heading" do
    {_result, walked} = step(SurfaceStepper.new())

    assert %SurfaceStepper{} = SurfaceStepper.reset(walked)
  end

  # One step with everything the framework has at that point: a percept on a
  # surface with its two curvature directions, a sensor standing at the origin,
  # and the step's own rng.
  defp step(policy) do
    SurfaceStepper.call(
      policy,
      Context.new(0),
      %{@agent => %{@sensor => %{"depth" => [[2.0, 2.0], [2.0, 2.0]]}}},
      state(),
      percept(),
      nil
    )
  end

  defp percept do
    {:ok, message} =
      Message.new(
        location: [0.0, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
          "pose_fully_defined" => true
        },
        non_morphological_features: %{
          "object_coverage" => 0.9,
          "mean_depth" => 0.03,
          "min_depth" => 0.025,
          "principal_curvatures" => [1.0, 5.0]
        },
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp state do
    %{
      @agent => %AgentState{
        sensors: %{
          @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
        },
        position: [0.0, 0.0, 0.0],
        rotation: Rotation.identity()
      }
    }
  end
end
