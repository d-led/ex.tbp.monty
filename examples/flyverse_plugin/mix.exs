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
  # The plugin package is pinned by revision rather than by version, and the
  # reason is a fact about the release rather than a preference: `0.1.1` cannot
  # report what a host carries (`MontyPlugin.Capabilities.carried/0`), so this
  # node's tags would be the plugin tags and nothing else, and a studio would
  # refuse the policy with "offered, but by no node that can serve it: … does not
  # offer :monty". `0.1.2` is that fix, it is on `main`, and it is not on Hex
  # yet. When it is, this line becomes `{:ex_monty_plugin, "~> 0.1.2"}` and
  # nothing else changes.
  defp deps do
    [
      {:ex_monty_plugin,
       github: "d-led/ex_monty_plugin", rev: "7e0de811f273ac9c851ff6803fe9e169e017b0e2"},
      {:ex_tbp_monty_core, "~> 0.1"},
      {:rustler, "~> 0.38", runtime: false},
      {:jason, "~> 1.2"}
    ]
  end
end
