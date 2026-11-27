defmodule Monty.Simulators.Flygym.InterpreterTest do
  @moduledoc """
  Where a fly's body is looked for, and what a machine is told when it has none.

  No body is started here: the question is which interpreter the world would use,
  and a file that stands where one would be is enough to ask it.
  """

  use ExUnit.Case, async: false

  alias Monty.Simulators.Flygym.World
  alias Monty.Test.Tmp

  describe "the interpreter" do
    test "is the one the environment names, before any installed one" do
      Tmp.system_env("FLYGYM_PYTHON", "/somewhere/else/python")

      assert World.interpreter() == "/somewhere/else/python"
      assert World.available?()
    end

    test "is the one in this application's data directory when nothing is named" do
      Tmp.without_env("FLYGYM_PYTHON")
      Tmp.system_env("MONTY_DATA", Tmp.dir("fly-interpreter"))
      installed = World.installed_path()

      assert String.starts_with?(installed, System.get_env("MONTY_DATA"))
      assert World.interpreter() == nil, "nothing is there yet"

      File.mkdir_p!(Path.dirname(installed))
      File.write!(installed, "#!/bin/sh\n")

      assert World.interpreter() == installed
    end

    test "is nowhere, and the reason names both places, when a machine has none" do
      Tmp.without_env("FLYGYM_PYTHON")
      Tmp.system_env("MONTY_DATA", Tmp.dir("fly-interpreter-none"))

      refute World.available?()

      reason = World.unavailable_reason()
      assert reason =~ "FLYGYM_PYTHON"
      assert reason =~ World.installed_path()
      assert reason =~ "4.0.1"
    end
  end
end
