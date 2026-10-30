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

  The classifier needs a Python interpreter but not Monty's environment: it only
  parses source. `$PYTHON`, then `python3` from the PATH.
  """

  use Mix.Task

  alias Monty.Config.Source
  alias Monty.ModuleMap

  @script "scripts/classify_monty_classes.py"

  @impl Mix.Task
  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: [json: :string, python: :string])
    python = options[:python] || System.get_env("PYTHON") || System.find_executable("python3")

    python ||
      Mix.raise("no python3 on the PATH: pass --python or set $PYTHON")

    planned = planned_classes()
    path = planned_path(planned)

    try do
      run_classifier(python, path, options[:json])
    after
      File.rm(path)
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

  defp run_classifier(python, planned, json_out) do
    arguments =
      [Path.expand(@script), "--monty-root", Source.root(), "--planned", planned, "--summary"]

    case System.cmd(python, arguments, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} when is_nil(json_out) ->
        :ok

      {_, 0} ->
        write_json(python, planned, json_out)

      {_, status} ->
        Mix.raise("#{@script} failed with status #{status}")
    end
  end

  defp write_json(python, planned, json_out) do
    arguments = [Path.expand(@script), "--monty-root", Source.root(), "--planned", planned]
    File.mkdir_p!(Path.dirname(json_out))

    case System.cmd(python, arguments ++ ["--out", json_out]) do
      {_, 0} -> Mix.shell().info("wrote #{json_out}")
      {output, status} -> Mix.raise("could not write #{json_out} (#{status}): #{output}")
    end
  end
end
