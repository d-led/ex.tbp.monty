defmodule Monty.Frameworks.EnvironmentUtils.Transforms.AddNoiseToRawDepthImage do
  @moduledoc """
  Gaussian noise on the raw depth image, before anything reads it.

  Mirrors
  `tbp/monty/frameworks/environment_utils/transforms.py::AddNoiseToRawDepthImage`.
  This is how Monty's noisy-camera experiments are noisy: a camera's depth is
  never exact, and an agent that only ever saw exact depths would be a different
  claim about what a surface agent can do.

  The noise is drawn per pixel, from this transform's own stream for the step —
  so two runs of the same episode seed see the same noisy depth, and a run
  without `sigma` sees none at all. A sensor with no depth is an error rather
  than a no-op: the experiment asked for noise on something that is not there
  (`Transforms.NoDepthSensorPresent`).
  """

  @behaviour Monty.Frameworks.EnvironmentUtils.Transforms.Transform

  alias Monty.Frameworks.EnvironmentUtils.Transforms.{NoDepthSensorPresent, TransformContext}

  @enforce_keys [:agent_id, :sigma]
  defstruct agent_id: nil, sigma: nil

  @type t :: %__MODULE__{agent_id: atom() | String.t(), sigma: float()}

  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sigma: Keyword.fetch!(options, :sigma)
    }
  end

  @doc "The transform a config describes."
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      agent_id: Map.fetch!(config, "agent_id"),
      sigma: Map.fetch!(config, "sigma")
    )
  end

  @impl true
  @spec call(map(), t(), TransformContext.t()) :: map()
  def call(observations, %__MODULE__{} = transform, %TransformContext{} = ctx) do
    agent = Map.fetch!(observations, transform.agent_id)

    noised =
      Enum.reduce(agent, %{}, fn {sensor_id, observation}, acc ->
        depth = depth!(observation, sensor_id)
        {noise, _rng} = draw(ctx.rng, transform.sigma, shape_of(depth))

        Map.put(acc, sensor_id, Map.put(observation, "depth", add(depth, noise)))
      end)

    Map.put(observations, transform.agent_id, noised)
  end

  defp depth!(observation, sensor_id) do
    case Map.fetch(observation, "depth") do
      {:ok, depth} -> depth
      :error -> raise NoDepthSensorPresent, "sensor #{inspect(sensor_id)} has no depth image"
    end
  end

  # A depth image is rows of numbers, one per pixel.
  defp shape_of(depth), do: {length(depth), depth |> hd() |> length()}

  # `count` draws from the step's stream. `:rand.normal_s/3` takes a variance
  # where numpy takes a standard deviation, hence the squaring.
  defp draw(rng, sigma, {rows, columns}) do
    Enum.map_reduce(1..(rows * columns), rng, fn _pixel, rng ->
      :rand.normal_s(0.0, sigma * sigma, rng)
    end)
  end

  defp add(depth, noise) do
    depth
    |> Enum.map(& &1)
    |> Enum.zip(Enum.chunk_every(noise, length(hd(depth))))
    |> Enum.map(fn {row, noise_row} ->
      Enum.zip_with([row, noise_row], fn [value, amount] -> value + amount end)
    end)
  end
end
