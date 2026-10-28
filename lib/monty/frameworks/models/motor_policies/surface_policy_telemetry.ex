defmodule Monty.Frameworks.Models.MotorPolicies.SurfacePolicyTelemetry do
  @moduledoc """
  Why a surface policy chose the action it chose.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::SurfacePolicyTelemetry`:
  which principal curvature the policy headed along, whether the step was one of
  its moves to get out of a tight spot, and the curvature vectors it used. A
  policy that is doing something strange is explained here rather than guessed
  at from the actions alone.
  """

  defstruct pc_heading: nil, avoidance_heading: nil, z_defined_pc: nil

  @type pc_heading :: :min | :max | :no | :jump | nil

  @type t :: %__MODULE__{
          pc_heading: pc_heading(),
          avoidance_heading: boolean() | nil,
          z_defined_pc: term()
        }
end
