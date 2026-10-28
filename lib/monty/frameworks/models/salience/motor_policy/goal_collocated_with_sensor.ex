defmodule Monty.Frameworks.Models.Salience.MotorPolicy.GoalCollocatedWithSensor do
  @moduledoc """
  Raised when a goal is where the sensor already is.

  Mirrors `tbp/monty/frameworks/models/salience/motor_policy.py::GoalCollocatedWithSensor`.
  There is no direction to look in when the target is at the eye, and Monty
  refuses rather than dividing a zero vector into an azimuth.
  """

  defexception message: "the goal is at the sensor, so there is no direction to look in"
end
