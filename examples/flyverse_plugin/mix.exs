defmodule FlyversePlugin.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :flyverse_plugin,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {FlyversePlugin.Application, []}]
  end

  # Four dependencies, and the reason for each is the point of the example:
  # `ex_monty_plugin` is the contract and the registry, `ex_tbp_monty_core` is
  # the framework whose actions this policy answers with, `rustler` compiles
  # `native/flyverse_nif` — a boundary over flyverse's own leaky
  # integrate-and-fire engine, so the spikes this node decides with are the
  # spikes that crate computes — and `jason` reads a pack's `plan.json`, which
  # is how a pack says which of its neurons are driven and which are read.
  #
  # `0.1.2` is the plugin package's first release that can report what a host
  # carries (`MontyPlugin.Capabilities.carried/0`); `0.1.1` could not, so this
  # node's tags were the plugin tags and nothing else and a studio refused the
  # policy with "offered, but by no node that can serve it: … does not offer
  # :monty".
  defp deps do
    [
      {:ex_monty_plugin, "~> 0.1.2"},
      {:ex_tbp_monty_core, "~> 0.1"},
      {:rustler, "~> 0.38", runtime: false},
      {:jason, "~> 1.2"}
    ]
  end
end
