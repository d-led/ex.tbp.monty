defmodule Mix.Tasks.Monty.Readiness do
  @shortdoc "Says which of Monty's experiments can run here, and what blocks the rest"

  @moduledoc """
  Opens every experiment Monty ships and says what stops each one.

  A count of runnable experiments is not a plan: an experiment is refused
  because a class is not written **or** because its world is not carried, and
  those are different work. This prints both, then ranks the classes by the
  experiments each one blocks **alone** — the ones that start running the day
  that class lands, with nothing else needed.

      mix monty.readiness
      mix monty.readiness --world synthetic
      mix monty.readiness --all
      mix monty.readiness --json priv/monty/readiness.json

  `--world` overrides the world a setup is read for (the application's own
  choice otherwise, which is MuJoCo). `--all` also lists every refused
  experiment with its reasons; without it, only the classes are printed. The
  answer is `Monty.Studio.Readiness`'s — this task opens the catalogue and
  formats what it says.
  """

  use Mix.Task

  alias Monty.Studio.Readiness
  @impl Mix.Task
  def run(arguments) do
    {options, _rest} =
      OptionParser.parse!(arguments,
        strict: [world: :string, conf_dir: :string, json: :string, all: :boolean]
      )

    survey = Readiness.catalog(open_options(options))

    print(survey, options[:all] || false)
    write_json(survey, options[:json])
  end

  defp conf_dir_opts(options) do
    case options[:conf_dir] do
      nil -> []
      dir -> [conf_dir: dir]
    end
  end

  defp open_options(options) do
    case options[:world] do
      nil -> conf_dir_opts(options)
      world -> [world_simulator: world_named(world)] ++ conf_dir_opts(options)
    end
  end

  # The worlds a setup can be read for. Named here rather than turned into atoms
  # from the command line, which is how a typo becomes a crash instead of a
  # sentence.
  @worlds %{"mujoco" => :mujoco, "synthetic" => :synthetic, "habitat" => :habitat}

  defp world_named(world) do
    Map.get(@worlds, world) ||
      Mix.raise("unknown world #{inspect(world)}; one of #{Enum.join(Map.keys(@worlds), ", ")}")
  end

  defp print(survey, all?) do
    Mix.shell().info("""
    #{length(survey.entries)} experiments in Monty's tree
      runnable here:    #{survey.runnable}
      refused:          #{survey.refused}
      did not compose:  #{survey.did_not_compose}
    """)

    print_codes(survey.by_code)
    print_classes(survey.by_class)
    if all?, do: print_refused(survey.entries)
  end

  defp print_codes([]), do: :ok

  defp print_codes(by_code) do
    Mix.shell().info("Why the refusals name what they name:")

    for %{code: code, count: count} <- by_code do
      Mix.shell().info("  #{String.pad_trailing(to_string(code), 30)} #{count}")
    end

    Mix.shell().info("")
  end

  defp print_classes([]), do: Mix.shell().info("Nothing is missing a class.")

  defp print_classes(by_class) do
    Mix.shell().info("""
    A class, by the experiments it blocks alone (naming = every refused
    experiment that names it, including ones another class also blocks):
    """)

    for %{class: class, alone: alone, naming: naming} <- by_class do
      Mix.shell().info(
        "  #{String.pad_trailing(class, 32)} alone #{String.pad_leading(to_string(alone), 3)}" <>
          "  naming #{String.pad_leading(to_string(naming), 3)}"
      )
    end

    Mix.shell().info("")
  end

  defp print_refused(entries) do
    Mix.shell().info("Every refused experiment:")

    for entry <- entries, entry.status != :runnable do
      Mix.shell().info("  #{entry.name} — #{Enum.join(entry.codes, ", ")}")
    end
  end

  defp write_json(_survey, nil), do: :ok

  defp write_json(survey, path) do
    File.write!(path, Jason.encode!(survey, pretty: true))
    Mix.shell().info("wrote #{path}")
  end
end
