defmodule Monty.Frameworks.Models.MotorSystem.SurfacePolicyActionDetailsTelemetry do
  @moduledoc """
  What a surface policy wants remembered about the actions it just chose.

  Mirrors `tbp/monty/frameworks/models/motor_system.py::SurfacePolicyActionDetailsTelemetry`.
  One entry per step, in the order the steps happened:

    * `pc_heading` — which principal curvature the policy headed for, `"min"`,
      `"max"`, `"no"` or `"jump"`, or `nil` when it is not a surface move;
    * `avoidance_heading` — whether the step was one of the policy's moves to
      get out of a tight spot;
    * `z_defined_pc` — the principal curvature vectors the policy used.

  Monty keeps this on the motor system because there is nowhere else for it to
  go yet ("TODO: Get rid of this once we have another path for telemetry"), and
  the same is true here.
  """

  defstruct pc_heading: [], avoidance_heading: [], z_defined_pc: []

  @type pc_heading :: :min | :max | :no | :jump | nil

  @type t :: %__MODULE__{
          pc_heading: [pc_heading()],
          avoidance_heading: [boolean() | nil],
          z_defined_pc: [term()]
        }

  @doc """
  Adds one step's worth of telemetry, at the end.

  A step with no telemetry adds nothing, which is what keeps the three lists the
  same length as the list of steps that had a surface policy.
  """
  @spec append(t(), term()) :: t()
  def append(%__MODULE__{} = telemetry, nil), do: telemetry

  def append(%__MODULE__{} = telemetry, step) do
    %__MODULE__{
      pc_heading: telemetry.pc_heading ++ [Map.get(step, :pc_heading)],
      avoidance_heading: telemetry.avoidance_heading ++ [Map.get(step, :avoidance_heading)],
      z_defined_pc: telemetry.z_defined_pc ++ [Map.get(step, :z_defined_pc)]
    }
  end
end
