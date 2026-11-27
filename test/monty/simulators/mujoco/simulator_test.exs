defmodule Monty.Simulators.Mujoco.SimulatorTest do
  @moduledoc """
  Translations of `tests/unit/simulators/mujoco/mujoco_simulator_test.py`.

  Monty's two remaining cases drive the simulator *class*: `add_object` twice and
  `remove_all_objects`, then adding a custom object again after everything was
  removed and finding its mesh, material and texture back. That API lives in the
  Python world this port carries for the embedded interpreter
  (`priv/monty_py/world.py`), which is where it is exercised; the Elixir side
  configures a scene and drives it through the port protocol rather than adding
  geoms through a `MjSpec`.

  So the two cases have no ExUnit counterpart, and they are recorded as
  exclusions rather than dropped. A file with no tests is the honest shape of
  that.
  """

  use ExUnit.Case, async: true

  # excluded test_remove_all_objects: the object API is the Python world's (priv/monty_py/world.py)
  # excluded test_adding_custom_objects_after_removing_all: the object API is the Python world's
end
