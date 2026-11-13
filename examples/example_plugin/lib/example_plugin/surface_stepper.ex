defmodule ExamplePlugin.SurfaceStepper do
  @moduledoc """
  A motor policy offered by this node: the framework's curvature-informed surface
  policy, made a plugin.

  `SurfacePolicyCurvatureInformed` is the policy Monty's own surf-agent
  experiments step with, and the difference from `ExamplePlugin.Policy` is the
  point of having both: the spiral only turns the sensor where it stands, while
  this one **moves** — a step is a translation along the surface plus the
  orienting that keeps the sensor on it — so a run driven by it can walk to what
  it is being asked about and recognise an object.

  The numbers mirror Monty's
  `conf/monty/motor_system_config/policy/surface_curvature_informed_goal1.yaml`
  and the `constant_surf` sampler that config names. They are repeated here rather
  than read from it because the conf tree belongs to the application that runs the
  experiment, not to the plugin: a plugin that read the caller's config would not
  be a plugin.

  It stays `:anywhere`: it holds no part, no handle and no file — the state it
  keeps between steps is a heading, a curvature direction and three counters,
  which is small enough to answer a call from any node.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{MoveForward, MoveTangentially, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicy, SurfacePolicyCurvatureInformed}

  @enforce_keys [:policy]
  defstruct [:policy]

  @type t :: %__MODULE__{policy: SurfacePolicyCurvatureInformed.t()}

  @agent_id "agent_id_0"

  @doc "The name a cluster registers it under."
  @spec name() :: String.t()
  def name, do: "example_plugin.surface_stepper"

  @doc "What a cluster asks about it."
  @spec describe() :: MontyPlugin.description()
  def describe do
    %{
      "name" => name(),
      "kind" => :motor_policy,
      "version" => ExamplePlugin.version(),
      "placement" => :anywhere,
      "needs" => [:monty]
    }
  end

  @doc "The policy, built the way the surf-agent config builds it."
  @spec new(keyword()) :: t()
  def new(_options \\ []) do
    %__MODULE__{policy: SurfacePolicyCurvatureInformed.new(options())}
  end

  @doc "One step of the surface walk, and the policy as it now stands."
  @impl MotorPolicy
  def call(%__MODULE__{policy: policy}, ctx, observations, state, percept, goal) do
    {result, policy} =
      SurfacePolicyCurvatureInformed.call(policy, ctx, observations, state, percept, goal)

    {result, %__MODULE__{policy: policy}}
  end

  @doc "Starts the next episode at the surface, not at a heading from the last one."
  @impl MotorPolicy
  def reset(%__MODULE__{policy: policy}),
    do: %__MODULE__{policy: SurfacePolicyCurvatureInformed.reset(policy)}

  @doc "What the policy recorded, which the ported policy reports as nothing."
  @impl MotorPolicy
  def state_dict(%__MODULE__{policy: policy}),
    do: SurfacePolicyCurvatureInformed.state_dict(policy)

  defp options do
    [
      action_sampler:
        ConstantSampler.new(
          actions: [MoveForward, MoveTangentially, OrientHorizontal, OrientVertical]
        ),
      agent_id: @agent_id,
      use_goal_driven_actions: true,
      desired_object_distance: 0.025,
      alpha: 0.1,
      pc_alpha: 0.5,
      max_pc_bias_steps: 32,
      min_general_steps: 8,
      min_heading_steps: 12
    ]
  end
end
