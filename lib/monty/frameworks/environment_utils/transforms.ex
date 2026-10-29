defmodule Monty.Frameworks.EnvironmentUtils.Transforms do
  @moduledoc """
  What an experiment does to observations before anything reads them.

  Mirrors `tbp/monty/frameworks/environment_utils/transforms.py`, which holds the
  transforms Monty's `env_interface_args` configure. What is ported so far:

    * `...Transforms.Transform` — **ported**: the interface, `call/2`;
    * `...Transforms.MissingToMaxDepth` — **ported**: depth where nothing was
      seen becomes the furthest the sensor can see.

  Still planned: `DepthTo3DLocations`, `AddNoiseToRawDepthImage`,
  `GaussianSmoothing`, `RandomJitter` and the rest. A config that names one of
  them is reported by `Monty.Studio.Setup` rather than silently dropped: the
  transforms that run are the ones this port has, and a run without
  `DepthTo3DLocations` is a run whose sensor reads a depth image directly.

  ## Why they matter here

  `MissingToMaxDepth` is not housekeeping. A Habitat depth image has 0 where no
  mesh is present, and a surface agent's search asks whether the centre of its
  view is nearer than a metre — a 0 would be read as an object at zero distance
  (`docs/monty-bugs.md` §1.7). Monty's experiments configure the transform; a
  world that reports 0 and applies nothing is a different experiment.
  """

  @doc """
  The transform a config describes.
  """
  @spec from_config(map()) :: struct()
  def from_config(%{"_target_" => _target} = config) do
    Monty.Config.Target.class!(config).from_config(config)
  end

  @doc """
  Every transform of a config list that this port can build.
  """
  @spec build([map()]) :: [struct()] | {:error, term()}
  def build(configs) do
    if Enum.all?(configs, &Monty.Config.Target.implemented?/1) do
      Enum.map(configs, &from_config/1)
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  Run a list of transforms in the order they were configured.

  Monty's transforms run in sequence, each seeing what the one before it left —
  `MissingToMaxDepth` then `DepthTo3DLocations`, and never the other way round.
  """
  @spec run([struct()], map()) :: map()
  def run(transforms, observations) do
    Enum.reduce(transforms, observations, fn %module{} = transform, observations ->
      module.call(observations, transform)
    end)
  end
end
