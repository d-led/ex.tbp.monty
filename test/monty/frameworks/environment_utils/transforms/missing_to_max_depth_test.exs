defmodule Monty.Frameworks.EnvironmentUtils.Transforms.MissingToMaxDepthTest do
  @moduledoc """
  Depth where nothing was seen, as Monty's experiments make it.

  Habitat reports 0 where no mesh is present; the transform reports the furthest
  the sensor can see instead, so a policy asking "is the middle of my view nearer
  than a metre?" gets an answer about the world rather than about the renderer.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.EnvironmentUtils.Transforms.MissingToMaxDepth

  defp transform(options \\ []) do
    MissingToMaxDepth.new(Keyword.merge([agent_id: "agent_id_0", max_depth: 1.0], options))
  end

  defp observations(depth) do
    %{"agent_id_0" => %{"patch" => %{"depth" => depth, "rgba" => [[0.0, 0.0, 0.0, 1.0]]}}}
  end

  defp depth(observations), do: get_in(observations, ["agent_id_0", "patch", "depth"])

  test "a pixel that saw nothing becomes the furthest the sensor can see" do
    transformed = MissingToMaxDepth.call(observations([[0.0]]), transform(), nil)

    assert depth(transformed) == [[1.0]]
  end

  test "and a pixel that saw something is left alone" do
    transformed = MissingToMaxDepth.call(observations([[0.05]]), transform(), nil)

    assert depth(transformed) == [[0.05]]
  end

  test "every pixel of an image is looked at" do
    transformed =
      MissingToMaxDepth.call(observations([[0.0, 0.2], [0.3, 0.0]]), transform(), nil)

    assert depth(transformed) == [[1.0, 0.2], [0.3, 1.0]]
  end

  test "a threshold says what counts as missing" do
    # A sensor that reports a small depth for noise needs a threshold above it.
    transformed =
      MissingToMaxDepth.call(observations([[0.01, 0.5]]), transform(threshold: 0.05), nil)

    assert depth(transformed) == [[1.0, 0.5]]
  end

  test "a sensor the transform was not for is left alone" do
    observations = %{"agent_id_1" => %{"patch" => %{"depth" => [[0.0]]}}}

    assert MissingToMaxDepth.call(observations, transform(), nil) == observations
  end

  test "and an observation with no depth at all is not given one" do
    observations = %{"agent_id_0" => %{"patch" => %{"rgba" => []}}}

    assert MissingToMaxDepth.call(observations, transform(), nil) == observations
  end

  describe "from a config" do
    test "it takes the agent and the furthest distance it was given" do
      config = %{
        "_target_" => "tbp.monty.frameworks.environment_utils.transforms.MissingToMaxDepth",
        "agent_id" => "agent_id_0",
        "max_depth" => 1
      }

      assert MissingToMaxDepth.from_config(config) ==
               %MissingToMaxDepth{agent_id: "agent_id_0", max_depth: 1, threshold: 0.0}
    end
  end
end
