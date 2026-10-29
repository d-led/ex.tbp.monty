defmodule Monty.Frameworks.Models.SensorModules.DefaultMessageNoise do
  @moduledoc """
  The noise layer a config asks for with `noise_params`.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::DefaultMessageNoise`.
  The parameters say how much to move each thing:

      noise_params:
        features:
          principal_curvatures_log: [0.1, 0.1]
          pose_vectors: 2.0        # degrees
        location: 0.001            # metres

  A real-valued feature gets Gaussian noise of that standard deviation added to
  it; a boolean flips with that *probability*; a hue is clipped back into
  `[0, 1]` after the noise because there is no colour outside it. A
  `pose_vectors` is not nudged component by component — that would stop the three
  directions being a frame — but turned by a small sampled rotation.

  Features are only noised when the percept carries features at all: a step that
  is a location and nothing else is not worth learning from, and Monty does not
  pretend otherwise.
  """

  @behaviour Monty.Frameworks.Models.SensorModules.MessageNoise

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @enforce_keys [:noise_params]
  defstruct noise_params: %{}

  @type t :: %__MODULE__{noise_params: map()}

  @spec new(map()) :: t()
  def new(noise_params), do: %__MODULE__{noise_params: noise_params}

  @impl true
  def call(%__MODULE__{} = noise, %Message{} = percept, rng) do
    {noisy, _rng} = apply_noise(noise, percept, rng)
    noisy
  end

  defp apply_noise(%__MODULE__{noise_params: params} = noise, %Message{} = percept, rng) do
    {percept, rng} =
      if Map.has_key?(params, "features") and percept.process_features_in_lm do
        noise_features(noise, percept, rng)
      else
        {percept, rng}
      end

    # The location is moved whatever the percept carries: where a sensor is is a
    # measurement with an error of its own.
    case Map.fetch(params, "location") do
      {:ok, sigma} ->
        {offset, rng} = normal(rng, sigma, 3)
        {%{percept | location: SpatialArithmetics.add(percept.location, offset)}, rng}

      :error ->
        {percept, rng}
    end
  end

  defp noise_features(%__MODULE__{noise_params: %{"features" => features}}, percept, rng) do
    {morphological, non_morphological, rng} =
      Enum.reduce(
        features,
        {percept.morphological_features, percept.non_morphological_features, rng},
        fn {name, amount}, {morphological, non_morphological, rng} ->
          {morphological, rng} = noise_entry(morphological, name, amount, rng)
          {non_morphological, rng} = noise_entry(non_morphological, name, amount, rng)
          {morphological, non_morphological, rng}
        end
      )

    {%{
       percept
       | morphological_features: morphological,
         non_morphological_features: non_morphological
     }, rng}
  end

  defp noise_entry(features, name, amount, rng) do
    case Map.fetch(features, name) do
      {:ok, value} ->
        {noised, rng} = noise_value(name, value, amount, rng)
        {Map.put(features, name, noised), rng}

      :error ->
        {features, rng}
    end
  end

  # A pose is a frame, so it is turned rather than nudged: three angles in
  # degrees, one for each axis.
  defp noise_value("pose_vectors", %SurfacePoseVectors{} = pose_vectors, sigma, rng) do
    {angles, rng} = normal(rng, sigma, 3)
    {:ok, rotation} = Rotation.from_euler_degrees(angles)

    {SpatialArithmetics.rotate_pose_vectors(pose_vectors, rotation), rng}
  end

  # A boolean's noise amount is the probability that it flips, not a spread.
  defp noise_value(_name, value, probability, rng) when is_boolean(value) do
    {draw, rng} = :rand.uniform_s(rng)
    {if(draw < probability, do: not value, else: value), rng}
  end

  # There is no hue outside the wheel, and Monty keeps it on it.
  defp noise_value("hsv", values, sigma, rng) do
    {noise, rng} = normal(rng, sigma, length(values))
    [hue | rest] = add_elementwise(values, noise)

    {[hue |> max(0.0) |> min(1.0) | rest], rng}
  end

  defp noise_value(_name, values, sigma, rng) when is_list(values) do
    {noise, rng} = normal(rng, sigma, length(values))
    {add_elementwise(values, noise), rng}
  end

  defp noise_value(_name, value, sigma, rng) when is_number(value) do
    {[noise], rng} = normal(rng, sigma, 1)
    {value + noise, rng}
  end

  defp add_elementwise(values, noise) do
    Enum.zip_with([values, noise], fn [value, amount] -> value + amount end)
  end

  # `count` draws of a Gaussian of standard deviation `sigma`, from the stream
  # this call was given. `:rand.normal_s/3` takes a variance, where Monty's
  # `rng.normal(0, sigma)` takes a standard deviation, so the squaring is the
  # translation and not an accident.
  defp normal(rng, sigma, count) do
    Enum.map_reduce(1..count, rng, fn _draw, rng -> :rand.normal_s(0.0, sigma * sigma, rng) end)
  end
end
