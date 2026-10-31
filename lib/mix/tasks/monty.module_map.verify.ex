defmodule Mix.Tasks.Monty.ModuleMap.Verify do
  @shortdoc "Fails when the module map has drifted from the Python checkouts"

  @moduledoc """
  Checks three things, for both packages this application mirrors:

      mix monty.module_map.verify
      mix monty.module_map.verify --source ../monty-orig --teleop-source ../tbp.teleop

    * every Python file in a checkout has an entry;
    * every entry marked `implemented` points at a module that exists;
    * every entry marked `excluded` says why.

  It also reports a checkout that has moved since the map was generated: the map
  records the commits it was read from, so a `git pull` is a fact about the map
  rather than something to remember. A moved checkout is an error to read, not a
  failure: the map still describes the commits it names.

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
          "module map: #{summary.files} files, #{summary.classes} classes — " <>
            "#{summary.implemented} implemented, #{summary.planned} planned, " <>
            "#{summary.excluded} excluded, per package: #{inspect(summary.by_package)}"
        )

        ModuleMap.moved()
        |> Enum.each(fn {package, recorded, current} ->
          Mix.shell().error(
            "module map: #{package} has moved since this map was generated — " <>
              "the map describes #{short(recorded)}, the checkout is at #{short(current)}; " <>
              "run `mix monty.module_map.gen` and read the diff"
          )
        end)

      {:error, problems} ->
        Enum.each(problems, fn problem -> Mix.shell().error(problem) end)
        Mix.raise("#{length(problems)} module map problem(s)")
    end
  end

  defp short(nil), do: "?"
  defp short(commit), do: String.slice(commit, 0, 7)
end
