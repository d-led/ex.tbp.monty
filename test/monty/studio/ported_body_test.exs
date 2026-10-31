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
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
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

  test "the run steps the model its config names, not this port's runtime" do
    {:ok, run} = Run.start(setup(), steps: 1)

    try do
      assert run.model == MontyForEvidenceGraphMatching
      assert {:ok, _info, _observations, _run} = Run.step(run)
    after
      Run.stop(run)
    end
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

      assert run.interface.env.world.agent.position != [0.0, 0.0, 0.0]
    after
      Run.stop(run)
    end
  end

  test "the patch lands on the object, so the module has something to match" do
    {:ok, opened} = Monty.Studio.open(@experiment, pretrained_dir: pretrained_dir())
    {:ok, run} = Run.start(opened.setup, steps: 1)

    try do
      {:ok, _info, _observations, run} = Run.step(run)

      # A patch that misses the object reports `on_object: 0`, the buffer never
      # counts an observation, and the module builds no hypothesis space at all:
      # the run then steps for as long as you let it with nothing to match.
      assert [belief] = run |> Run.beliefs() |> Map.values()
      assert belief.possible_matches != []
      assert belief.mlh.graph_id in opened.setup.object_names
      assert belief.mlh.evidence > 0.0
    after
      Run.stop(run)
    end
  end

  # The exported library, named by the release it came from. Only the last two
  # segments are read, so the test runs without Monty's models on this machine.
  defp pretrained_dir, do: Path.join(__DIR__, "pretrained_ycb_v13")
end
