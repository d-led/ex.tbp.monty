defmodule Monty.Studio do
  @moduledoc """
  The front door of the studio: open an experiment, or preview one that does not
  exist yet.

  Everything a page needs for "before the run" comes from here — the setup, its
  diagram, what is wrong with it — so the index, the builder and the experiment
  page cannot drift apart in how they read a config.
  """

  alias Monty.Studio.{Blueprint, Diagram, Drafts, Setup}

  @type opened :: %{
          name: String.t(),
          source: :draft | :monty,
          setup: Setup.t(),
          diagram: Diagram.t(),
          yaml: String.t() | nil,
          groups: %{optional(String.t()) => String.t()},
          config: map()
        }

  @doc """
  Opens an experiment by name.

  A draft in `Monty.Studio.Drafts` wins, because that is the one a person just
  built; otherwise the name is a Monty experiment and is composed from Monty's
  own conf tree.
  """
  @spec open(String.t(), keyword()) :: {:ok, opened()} | {:error, term()}
  def open(name, opts \\ []) do
    if Drafts.exists?(name) do
      with {:ok, text} <- Drafts.read(name),
           {:ok, tree} <- Monty.Config.Composer.compose_yaml(text) do
        {:ok, describe(name, :draft, tree, text, groups_of(text))}
      end
    else
      with {:ok, tree} <- Monty.Config.Composer.compose(name, Keyword.take(opts, [:conf_dir])) do
        {:ok, describe(name, :monty, tree, nil, groups_of_name(name))}
      end
    end
  end

  @doc """
  What a blueprint would be if it were opened.

  Findings are reported whether or not the config composes: a builder must be
  able to say "this option does not exist" before anything is written.
  """
  @spec preview(Blueprint.t(), keyword()) :: map()
  def preview(%Blueprint{} = blueprint, opts \\ []) do
    findings = Blueprint.findings(blueprint, opts)
    yaml = Blueprint.to_yaml(blueprint)

    case Setup.from_text(yaml, Keyword.put(opts, :name, blueprint.name)) do
      {:ok, setup} ->
        %{
          blueprint: blueprint,
          yaml: yaml,
          findings: findings ++ setup.findings,
          setup: setup,
          diagram: Diagram.new(setup)
        }

      {:error, reason} ->
        %{
          blueprint: blueprint,
          yaml: yaml,
          findings:
            findings ++
              [
                Monty.Studio.Finding.new(
                  :error,
                  :does_not_compose,
                  "This config does not compose: #{inspect(reason)}",
                  "defaults"
                )
              ],
          setup: nil,
          diagram: nil
        }
    end
  end

  defp describe(name, source, tree, yaml, groups) do
    setup = Setup.new(tree, name: name)

    %{
      name: name,
      source: source,
      setup: setup,
      diagram: Diagram.new(setup),
      yaml: yaml,
      groups: groups,
      config: tree
    }
  end

  defp groups_of(text) do
    case Monty.Config.Source.load_text(text) do
      {:ok, config} -> choices(config.defaults)
      {:error, _reason} -> %{}
    end
  end

  defp groups_of_name(name) do
    case Monty.Studio.Catalog.experiment(name) do
      nil -> %{}
      experiment -> experiment.groups
    end
  end

  defp choices(defaults) do
    for {:group, group, option, _package} <- defaults,
        is_binary(option),
        into: %{} do
      {String.trim_leading(group, "/"), option}
    end
  end
end
