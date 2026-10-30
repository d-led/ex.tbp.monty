defmodule Mix.Tasks.Monty.PortCensusTest do
  @moduledoc """
  The census, run for real: it parses Monty's source, so what it says about a
  class is what Monty's source says.

  Two classes are enough to hold the seam: one that is behaviour and one that is
  an interface. If the classifier stops reading Monty's AST and starts guessing,
  these two answers change.
  """

  use ExUnit.Case, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "a class with a body is work, and a Protocol is not" do
    path = Path.join(System.tmp_dir!(), "port_census_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    Mix.Tasks.Monty.PortCensus.run(["--json", path])
    census = path |> File.read!() |> Jason.decode!()

    assert %{"kind" => "class", "behaviour" => "some", "methods" => methods} =
             census["tbp/monty/simulators/habitat/agents.py::SingleSensorAgent"]

    assert "get_spec" in methods

    assert %{"kind" => "protocol", "behaviour" => "none"} =
             census["tbp/monty/frameworks/actions/actions.py::LookDownActuator"]
  end
end
