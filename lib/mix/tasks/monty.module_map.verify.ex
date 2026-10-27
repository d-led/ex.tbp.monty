defmodule Mix.Tasks.Monty.ModuleMap.Verify do
  @shortdoc "Fails when the module map has drifted from the Monty checkout"

  @moduledoc """
  Checks three things:

      mix monty.module_map.verify
      mix monty.module_map.verify --source ../monty-orig

    * every Python file in the checkout has an entry;
    * every entry marked `implemented` points at a module that exists;
    * every entry marked `excluded` says why.

  This is what makes "module for module" a property of the repository rather
  than a claim in a README.
  """

  use Mix.Task

  alias Monty.ModuleMap

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [source: :string])

    case ModuleMap.verify(opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "module map: #{summary.modules} modules, " <>
            "#{summary.implemented} implemented, #{summary.planned} planned, " <>
            "#{summary.excluded} excluded"
        )

      {:error, problems} ->
        Enum.each(problems, fn problem -> Mix.shell().error(problem) end)
        Mix.raise("#{length(problems)} module map problem(s)")
    end
  end
end
