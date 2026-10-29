defmodule Monty.Studio.PortedBodyTest do
  @moduledoc """
  A studio run driven by the body the experiment names.

  This is the whole loop with Monty's own parts on it: the config's motor system
  and policy choose actions, the world moves by them, the sensor reports the
  surface it is looking at, and the next step sees the result. The only stand-in
  left is the world itself, which is a sphere — so what this proves is that the
  parts agree, not that the numbers are Monty's.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Actions.ActionJSONEncoder
  alias Monty.Frameworks.Models.MotorPolicies.SurfacePolicyCurvatureInformed
  alias Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector
  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Studio.{Run, Setup}

  @experiment "base_config_10distinctobj_surf_agent"

  defp setup do
    {:ok, opened} = Monty.Studio.open(@experiment)
    opened.setup
  end

  test "the surf agent's body comes from its config" do
    motor =
      setup()
      |> Setup.model_spec("ported-body-spec")
      |> Map.fetch!(:motor)

    assert {MotorSystem, %MotorSystem{policy_selector: %SinglePolicySelector{policy: policy}}} =
             motor

    assert %SurfacePolicyCurvatureInformed{agent_id: "agent_id_0"} = policy
  end

  test "and it steers a run: the actions are Monty's, and the world moves by them" do
    {:ok, run} = Run.start(setup(), steps: 5)

    try do
      # An action reaches the world on the *next* step, so a surface agent's
      # cycle — orient, orient, step tangentially, close in — has to be given a
      # few steps before it has moved the agent anywhere.
      run = Enum.reduce(1..5, run, fn _step, run -> elem(Run.step(run), 3) end)

      assert [first | _rest] = run.pending_actions
      assert %{"action" => _name, "agent_id" => "agent_id_0"} = ActionJSONEncoder.encode(first)

      assert run.environment.world.agent.position != [0.0, 0.0, 0.0]
    after
      Run.stop(run)
    end
  end
end
