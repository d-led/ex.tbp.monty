defmodule Monty.Studio.Index do
  @moduledoc """
  A faceted index over every experiment, for a list a person can actually use.

  Monty ships a hundred experiments and will ship more; a hundred rows is not a
  list you read, it is a list you grep. So the index is built the way a catalog
  is built rather than the way a table is:

    * every experiment gets the handful of labels a person asks about — which
      agent it drives, how many learning modules, which family of learning
      module, whether it starts from a trained model — derived from its config,
      not from its name alone;
    * **facets carry counts that respect the other filters**, so "surface agent
      (12)" means twelve, not twelve-if-you-ignore-everything-else;
    * a filter is a set of pills with a visible count, never a syntax to learn;
    * the index is a value: `build/1` and `filter/2` are pure, so the same
      filtering the page does can be tested with a fixture of three experiments
      and with all of Monty's.

  Labels are deliberately coarse. "Evidence matching", "one module", "distant
  agent" are choices a person makes; `evidence_1lm_nn10_dod003_dts02_gsg0` is a
  filename.
  """

  @type entry :: %{
          name: String.t(),
          agent: String.t(),
          modules: non_neg_integer(),
          learning_module: String.t(),
          model: String.t(),
          groups: %{optional(String.t()) => String.t()},
          search: String.t()
        }

  @type value :: %{value: String.t(), label: String.t(), count: non_neg_integer()}

  @type facet :: %{key: String.t(), label: String.t(), values: [value()]}

  @type t :: %__MODULE__{entries: [entry()], facets: [facet()]}

  @type result :: %{
          entries: [entry()],
          facets: [facet()],
          matching: non_neg_integer(),
          total: non_neg_integer(),
          filtered?: boolean(),
          active: %{optional(String.t()) => [String.t()]}
        }

  defstruct entries: [], facets: []

  @facets [
    %{key: "agent", label: "Agent"},
    %{key: "modules", label: "Learning modules"},
    %{key: "learning_module", label: "Learning module"},
    %{key: "model", label: "Starts from"}
  ]

  @doc "Builds the index from catalog entries."
  @spec build([map()]) :: t()
  def build(experiments) do
    entries = experiments |> Enum.map(&entry/1) |> Enum.sort_by(& &1.name)

    %__MODULE__{entries: entries, facets: facets(entries)}
  end

  @doc """
  Narrows the index with the query parameters a page carries.

  `"q"` is the search box — every word must appear somewhere in the name or in
  a chosen group option. Every other key is a facet, and a facet may hold
  several values: values inside a facet are alternatives, facets are combined.
  """
  @spec filter(t(), map()) :: result()
  def filter(%__MODULE__{} = index, params) do
    active = active(params)
    entries = apply_filters(index.entries, active)

    %{
      entries: entries,
      facets: facets(index.entries, active),
      matching: length(entries),
      total: length(index.entries),
      filtered?: Enum.any?(active, fn {_key, values} -> values != [] end),
      active: active
    }
  end

  @doc "The facet keys a page may put in a URL."
  @spec facet_keys() :: [String.t()]
  def facet_keys, do: Enum.map(@facets, & &1.key)

  # -- entries --------------------------------------------------------------

  defp entry(experiment) do
    groups = experiment.groups
    config = Map.get(experiment, :config) || %{}

    %{
      name: experiment.name,
      agent: agent(groups["environment"]),
      modules: modules(groups["monty/learning_module"], groups["monty/connectivity"]),
      learning_module: learning_module(groups["monty/learning_module"]),
      model: model(config),
      groups: groups,
      search: searchable(experiment)
    }
  end

  defp agent(environment) when is_binary(environment) do
    case Regex.run(~r/_(dist|surf|noop)_agent/, environment) do
      [_, kind] -> kind
      nil -> "other"
    end
  end

  defp agent(_absent), do: "other"

  defp modules(learning_module, connectivity) do
    count_from(learning_module) || count_from(connectivity) || 0
  end

  defp count_from(option) when is_binary(option) do
    case Regex.run(~r/(\d+)lm/, option) do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  defp count_from(_absent), do: nil

  defp learning_module(option) when is_binary(option) do
    option |> String.split("_", parts: 2) |> List.first()
  end

  defp learning_module(_absent), do: "unknown"

  defp model(config) do
    case Map.get(config, "model_name_or_path") do
      path when is_binary(path) and path != "" -> "pretrained"
      _scratch -> "scratch"
    end
  end

  defp searchable(experiment) do
    [experiment.name | Map.values(experiment.groups)]
    |> Enum.join(" ")
    |> String.downcase()
  end

  # -- filtering ------------------------------------------------------------

  defp active(params) do
    words = params |> Map.get("q", "") |> to_string() |> String.split(~r/\s+/u, trim: true)

    facet_values = Map.new(@facets, fn %{key: key} -> {key, list(params[key])} end)

    Map.put(facet_values, "q", words)
  end

  defp list(nil), do: []
  defp list(""), do: []
  defp list(values) when is_list(values), do: Enum.reject(values, &(&1 in [nil, ""]))

  defp list(values) do
    values |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp apply_filters(entries, active) do
    Enum.filter(entries, fn entry -> Enum.all?(active, &matches?(entry, &1)) end)
  end

  defp matches?(_entry, {"q", []}), do: true

  defp matches?(entry, {"q", words}) do
    Enum.all?(words, &String.contains?(entry.search, String.downcase(&1)))
  end

  defp matches?(_entry, {_facet, []}), do: true

  defp matches?(entry, {facet, values}) do
    entry |> value_of(facet) |> then(&(&1 in values))
  end

  defp value_of(entry, "agent"), do: entry.agent
  defp value_of(entry, "modules"), do: Integer.to_string(entry.modules)
  defp value_of(entry, "learning_module"), do: entry.learning_module
  defp value_of(entry, "model"), do: entry.model
  defp value_of(_entry, _unknown), do: ""

  # -- facets ---------------------------------------------------------------

  # Each facet counts under every *other* filter, which is what makes a count
  # useful: pick "surface agent" and the learning-module counts immediately say
  # what is still reachable.
  defp facets(entries, active \\ %{}) do
    for %{key: key, label: label} <- @facets do
      counts =
        entries
        |> apply_filters(Map.delete(active, key))
        |> Enum.frequencies_by(&value_of(&1, key))

      %{
        key: key,
        label: label,
        values:
          counts
          |> Enum.sort_by(fn {value, _count} -> sort_key(key, value) end)
          |> Enum.map(fn {value, count} ->
            %{value: value, label: label_for(key, value), count: count}
          end)
      }
    end
  end

  defp sort_key("modules", value) do
    case Integer.parse(value) do
      {number, ""} -> {0, number, ""}
      _not_a_number -> {1, 0, value}
    end
  end

  defp sort_key(_key, value), do: {0, 0, value}

  defp label_for("modules", "1"), do: "one"
  defp label_for("modules", value), do: value <> " modules"
  defp label_for("agent", "dist"), do: "distant"
  defp label_for("agent", "surf"), do: "surface"
  defp label_for("agent", "noop"), do: "no-op"
  defp label_for(_key, value), do: value
end
