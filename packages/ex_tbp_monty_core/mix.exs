defmodule ExTbpMonty.Core.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/d-led/ex.tbp.monty"

  def project do
    [
      app: :ex_tbp_monty_core,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 85]],

      # Hex.pm publishing: this package is the part of the port that stands on
      # its own — a sensorimotor core you can drive, not only run experiments
      # with. The application beside it (`../..`) is its main user.
      description: description(),
      package: package(),
      docs: docs(),
      name: "ExTbpMonty.Core",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      # No application callback on purpose: the core is processes a host starts
      # in its own tree (`ExTbpMonty.Core.Supervisor`), not a thing that runs
      # by itself. `extra_applications` is what the code actually calls.
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The nearest-neighbour index, feature matching and the curvature fit are
      # the hot loops Elixir cannot make cheap enough (`native/`). Rustler is a
      # build dependency, and the crate is compiled when this package is: the
      # build therefore wants a Rust toolchain, while the Elixir paths stay the
      # reference and the fallback for a VM where the NIF cannot be loaded.
      {:rustler, "~> 0.38", runtime: false},
      {:jason, "~> 1.2"},
      # `Monty.Config.Source` and the maps it reads are YAML/JSON, and a
      # telemetry span is how the runtime says what a step did.
      {:yaml_elixir, "~> 2.11"},
      {:telemetry, "~> 1.0"},
      # The stand-in scene draws its frame as HTML. The escaping is
      # `Phoenix.HTML`, which is a markup library, not the web framework.
      {:phoenix_html, "~> 4.1"},

      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:junit_formatter, "~> 3.4", only: :test},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A rewrite of the Thousand Brains Project's Sensorimotor Learning Framework Monty " <>
      "for the BEAM: learning modules, evidence and hypotheses, sensor modules, and the " <>
      "port a world plugs into. Monty for Elixir with a simpler entry point; the main " <>
      "repository runs experiments in a Phoenix LiveView."
  end

  defp package do
    [
      name: "ex_tbp_monty_core",
      # `native/` is the crates, and it has to travel: `priv/native/*.so` is what
      # *this* machine built, a NIF is loaded by the BEAM of the machine that
      # installs the package, and rustler compiles the crate for that platform at
      # `deps.compile` time. Shipping the binaries instead would hand a Linux host
      # a macOS library. `priv` is therefore not in the list — only what the
      # compiler needs to produce it.
      #
      # The crates are named file by file rather than as `native`: a Cargo
      # `target/` directory is a gigabyte of build output no package should
      # carry, and hex has no way to subtract one from a directory it was given.
      files:
        ~w(lib .formatter.exs mix.exs README.md LICENSE
           native/*/Cargo.toml native/*/Cargo.lock native/*/src),
      maintainers: ["Dmitry Ledentsov"],
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Monty" => "https://github.com/thousandbrainsproject/tbp.monty"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      source_url_pattern:
        "#{@source_url}/blob/v#{@version}/packages/ex_tbp_monty_core/%{path}#L%{line}",
      extras: [
        {"README.md", [title: "Overview"]},
        {"../../docs/module-map.md", [title: "Module map"]},
        {"../../docs/monty-differences.md", [title: "Differences from Monty"]}
      ]
    ]
  end

  # The same flags the application uses: this package has to survive the types
  # job on its own, not only as a dependency of something that does.
  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit, :tools],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end
end
