defmodule Mix.Tasks.Monty.PortCensus do
  @shortdoc "Says what kind of thing each class the map still calls planned is"

  @moduledoc """
  The port's backlog, by what the work actually is.

  A count of planned classes is not a count of work: Monty has `Protocol`s that
  are an interface and nothing else, `ABC`s whose methods all raise
  `NotImplementedError`, `TypedDict`s that are a dict's shape, and dataclasses
  that do arithmetic. Only the last kind is a module to write.

  This reads the module map for everything it calls `:planned`, asks
  `scripts/classify_monty_classes.py` what each of those classes is in Monty's
  own source, and prints the answer by kind and behaviour.

      mix monty.port_census
      mix monty.port_census --json priv/monty/port_census.json
      mix monty.port_census --python /path/to/conda/envs/tbp.monty/bin/python
      mix monty.port_census --all --monty-root ../monty-orig

  `--monty-root` reads a checkout other than the one `MONTY_SOURCE` names, and
  `--all` classifies every class in it instead of only the planned ones — which
  is what the census is a census of, and what a test can ask without a Monty
  checkout in sight.

  The classifier needs a Python interpreter but not Monty's environment: it only
  parses source. `$PYTHON`, then `python3` from the PATH.
  """

  use Mix.Task

  alias Monty.Config.Source
  alias Monty.ModuleMap

  @script "scripts/classify_monty_classes.py"

  @impl Mix.Task
  def run(arguments) do
    {options, _rest} =
      OptionParser.parse!(arguments,
        strict: [json: :string, python: :string, monty_root: :string, all: :boolean]
      )

    python = options[:python] || System.get_env("PYTHON") || System.find_executable("python3")

    python ||
      Mix.raise("no python3 on the PATH: pass --python or set $PYTHON")

    root = options[:monty_root] || Source.root()

    if options[:all] do
      classify(python, root, nil, options[:json])
    else
      planned = planned_path(planned_classes())

      try do
        classify(python, root, planned, options[:json])
      after
        File.rm(planned)
      end
    end
  end

  defp planned_classes do
    for entry <- ModuleMap.load(),
        class <- entry[:classes] || [],
        class.status == :planned do
      %{package: entry.package, file: entry.python, class: class.python}
    end
  end

  # The map says which file a class lives in and what it is called; the
  # classifier wants exactly those two facts, and nothing about Elixir.
  defp planned_path(planned) do
    path = Path.join(System.tmp_dir!(), "monty_planned_classes.json")
    File.write!(path, Jason.encode!(planned))
    path
  end

  # One call either way: a report on stdout, or the same report written to a
  # file the caller names.
  defp classify(python, root, planned, json_out) do
    extra =
      case json_out do
        nil ->
          ["--summary"]

        path ->
          File.mkdir_p!(Path.dirname(path))
          ["--out", path]
      end

    arguments =
      [Path.expand(@script), "--monty-root", root] ++
        if(planned, do: ["--planned", planned], else: []) ++ extra

    # The script says why it stopped, so its own words reach a person: a bare
    # "status 1" is what a missing checkout used to look like.
    {output, status} = System.cmd(python, arguments, stderr_to_stdout: true)

    case status do
      0 when is_nil(json_out) -> IO.write(output)
      0 -> Mix.shell().info("wrote #{json_out}")
      _failure -> Mix.raise("#{@script} failed with status #{status}: #{String.trim(output)}")
    end
  end
end
