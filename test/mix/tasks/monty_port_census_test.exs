defmodule Mix.Tasks.Monty.PortCensusTest do
  @moduledoc """
  The census, run for real against source it can read: two classes in a fixture
  checkout, one with a body and one `Protocol`.

  No Monty checkout, because nothing in the build may need one. What is held is
  the distinction the census exists to draw — a class with a body is work, a
  `Protocol` is an interface — and it is held by reading an AST, so a classifier
  that started guessing from names would answer differently here.
  """

  use ExUnit.Case, async: false

  alias Monty.Test.Tmp

  @checkout Path.expand("../../fixtures/classifier", __DIR__)
  @source "tbp/monty/shapes.py"

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "a class with a body is work, and a Protocol is not" do
    census = census(@checkout)

    assert %{"kind" => "class", "behaviour" => "some", "methods" => methods} =
             census["#{@source}::Recorder"]

    assert "record" in methods
    assert %{"kind" => "protocol", "behaviour" => "none"} = census["#{@source}::Sensor"]
  end

  test "a root with no source in it is an error, not an empty census" do
    path = Tmp.file("not_a_checkout")

    assert_raise Mix.Error, ~r/no Monty source/, fn ->
      Mix.Tasks.Monty.PortCensus.run(["--monty-root", path, "--all", "--json", path])
    end
  end

  defp census(root) do
    path = Tmp.file("port_census.json")

    Mix.Tasks.Monty.PortCensus.run(["--monty-root", root, "--all", "--json", path])

    path |> File.read!() |> Jason.decode!()
  end
end
