defmodule Mix.Tasks.Monty.ModuleMap.Verify do
  @shortdoc "Fails when the module map has drifted from the Python checkouts"

  @moduledoc """
  Checks three things, for both packages this application mirrors:

      mix monty.module_map.verify
      mix monty.module_map.verify --source ../monty-orig --teleop-source ../tbp.teleop

    * every Python file in a checkout has an entry;
    * every entry marked `implemented` points at a module that exists;
    * every entry marked `excluded` says why.

  This is what makes "module for module" a property of the repository rather
  than a claim in a README.
  """

  use Mix.Task

  alias Monty.ModuleMap

  @impl true
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [source: :string, teleop_source: :string])

    if source = opts[:source],
      do: Application.put_env(:ex_tbp_monty, :monty_source, Path.expand(source))

    if source = opts[:teleop_source],
      do: Application.put_env(:ex_tbp_monty, :teleop_source, Path.expand(source))

    case ModuleMap.verify() do
      {:ok, summary} ->
        Mix.shell().info(
          "module map: #{summary.modules} modules, " <>
            "#{summary.implemented} implemented, #{summary.planned} planned, " <>
            "#{summary.excluded} excluded, per package: #{inspect(summary.by_package)}"
        )

      {:error, problems} ->
        Enum.each(problems, fn problem -> Mix.shell().error(problem) end)
        Mix.raise("#{length(problems)} module map problem(s)")
    end
  end
end
