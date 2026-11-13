defmodule ExamplePlugin.OfferTest do
  @moduledoc """
  What happens to a plugin that does not describe itself usably: nothing is
  offered.

  A description is a map, so a mistake in it compiles. The registry would report
  it as "cannot be used" — which is honest, and too late: the cluster would list
  a name that nobody can call, and the operator would learn about it from a line
  in a sentence on somebody else's page. So the process refuses to start, and the
  application that holds it refuses too.
  """

  use ExUnit.Case, async: true

  defmodule HalfDescribed do
    @moduledoc false
    def describe, do: %{"name" => "half_described"}
  end

  defmodule NotEvenAMap do
    @moduledoc false
    def describe, do: "a motor policy, honestly"
  end

  test "a plugin with a missing field is not offered, and the reason names the field" do
    assert {:error, reason} = refused(HalfDescribed)

    assert reason =~ "`version` is missing"
  end

  test "a plugin that describes itself with something that is not a map is not offered" do
    assert {:error, reason} = refused(NotEvenAMap)

    assert reason =~ "a description is a map"
  end

  # `start_link` is what a supervisor calls, and a child that refuses to start
  # takes its caller down with it unless the caller is trapping exits — which a
  # supervisor is, and a test is not.
  defp refused(plugin) do
    Process.flag(:trap_exit, true)
    ExamplePlugin.Offer.start_link(plugin)
  end
end
