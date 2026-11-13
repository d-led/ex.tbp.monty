defmodule ExamplePlugin.Policy do
  @moduledoc """
  A motor policy offered by this node: the framework's scanning policy, made a
  plugin.

  The decision is not written here. `NaiveScanPolicy` is the ported policy — a
  square spiral, every action fixed at construction — and this module is the
  plugin around it: the description a cluster asks for, the calls a policy owes a
  run (`call/6`, `reset/1`, `state_dict/1`), and nothing that decides where to
  look.

  It is `:anywhere` rather than `:owner_only`: it reads no part, holds no handle,
  and the whole of its state is which leg of the spiral it is on, which is small
  enough to answer a call from any node. A policy that read a B-rep would have to
  say `:owner_only`, because that handle cannot leave the node that opened it.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Frameworks.Actions.{LookDown, LookUp, TurnLeft, TurnRight}
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicy, NaiveScanPolicy}

  @enforce_keys [:scan, :sensor_id]
  defstruct scan: nil, sensor_id: "sensor_0"

  @type t :: %__MODULE__{
          scan: NaiveScanPolicy.t(),
          sensor_id: String.t()
        }

  # Monty's own surf-agent experiments turn five degrees and step four
  # millimetres; the spiral makes no translation, so only the turn is used.
  @step_degrees 5.0
  @agent_id "agent_id_0"

  @doc "The name a cluster registers it under."
  @spec name() :: String.t()
  def name, do: "example_plugin.spiral_scan"

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

  @doc "The spiral, built by the ported policy's own constructor."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{scan: spiral(), sensor_id: Keyword.get(options, :sensor_id, "sensor_0")}
  end

  @doc """
  The next action of the spiral, and this policy as it now stands.

  The leg counter lives in the ported policy, so the answer is the spiral's and
  the only thing added here is the struct it is carried in.
  """
  @impl MotorPolicy
  def call(%__MODULE__{scan: scan} = policy, ctx, observations, state, percept, goal) do
    {result, scan} = NaiveScanPolicy.call(scan, ctx, observations, state, percept, goal)
    {result, %{policy | scan: scan}}
  end

  @doc "Starts the next episode at the first leg of the spiral."
  @impl MotorPolicy
  def reset(%__MODULE__{scan: scan} = policy), do: %{policy | scan: NaiveScanPolicy.reset(scan)}

  @doc """
  What the policy recorded, for a run that wants to be read afterwards.

  The ported policy reports nothing — a fixed spiral has nothing to report — so
  the position it is at is named here instead, because "which leg was it on when
  the run ended" is the one thing a reader of a spiral run does want.
  """
  @impl MotorPolicy
  def state_dict(%__MODULE__{scan: scan} = policy) do
    %{
      sensor_id: policy.sensor_id,
      current_action_id: scan.current_action_id,
      steps_per_action: scan.steps_per_action
    }
  end

  # The scanner never draws from its sampler — the four actions it makes are
  # fixed at construction — so the sampler is Monty's constant one holding the
  # four legs, which is what "constant" means here.
  defp spiral do
    NaiveScanPolicy.new(
      action_sampler: %ConstantSampler{
        actions: [LookUp, TurnLeft, LookDown, TurnRight],
        rotation_degrees: @step_degrees
      },
      agent_id: @agent_id,
      fixed_amount: @step_degrees
    )
  end
end
