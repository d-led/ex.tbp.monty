defmodule ExamplePlugin.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :example_plugin,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {ExamplePlugin.Application, []}]
  end

  # Two dependencies, and the reason for each is the point of the example:
  # `ex_monty_plugin` is the contract and the registry, and `ex_tbp_monty_core`
  # is the framework's own maths, so the learning module this node offers is not
  # a re-implementation of a threshold but the ported one.
  defp deps do
    [
      {:ex_monty_plugin, "~> 0.1.2"},
      {:ex_tbp_monty_core, "~> 0.1"}
    ]
  end
end
