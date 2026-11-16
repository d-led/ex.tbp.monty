defmodule Monty.Experiment.MatchCriteria do
  @moduledoc """
  Turning per-module terminal states into one system-level decision.

  Mirrors `tbp/monty/experiment/match_criteria.py`. A learning module concludes
  on its own — it recognised an object, it gave up, or it ran out of time — and
  something has to decide what the *system* believes. That is a criterion: a
  function of the terminal states of all modules.

    * `Monty.Experiment.MatchCriteria.AnyLMsMatch` — enough modules matched;
    * `Monty.Experiment.MatchCriteria.NamedLMsMatch` — these modules matched.

  A criterion is carried as `{module, argument}`, the same way this port carries
  a hypotheses updater: the module answers and the argument is the
  configuration, so an experiment picks a criterion without the coordinator
  knowing which one it got.
  """

  alias Monty.Experiment.MatchCriteria.{AnyLMsMatch, NamedLMsMatch}

  @doc """
  The criterion a config names, built.

  Monty's experiment reads `config["match_criterion"]` — which Hydra built from
  the class a termination config declares — and sets it on the model before the
  first episode. A criterion that cannot be built answers with Monty's
  `ValueError` sentence, so a run refuses rather than deciding by a criterion
  nobody asked for.
  """
  @spec from_config(map()) :: {:ok, {module(), term()}} | {:error, String.t()}
  def from_config(%{"_target_" => target} = config) do
    name = target |> String.split(".") |> List.last()

    case name do
      "AnyLMsMatch" -> build(AnyLMsMatch, "count", config)
      "NamedLMsMatch" -> build(NamedLMsMatch, "ids", config)
      _other -> {:error, "no match criterion named #{name}"}
    end
  end

  @doc """
  The criterion a model has when no experiment gave it one: one module matched.

  This is what a single-module experiment means, and it never ends an episode
  that concluded nothing.
  """
  @spec default() :: {module(), term()}
  def default, do: {AnyLMsMatch, %AnyLMsMatch{count: 1}}

  defp build(module, option, config) do
    case Map.fetch(config, option) do
      {:ok, argument} ->
        case module.new(argument) do
          {:ok, criterion} -> {:ok, {module, criterion}}
          {:error, reason} -> {:error, sentence(reason)}
        end

      :error ->
        {:error, "#{option} is missing"}
    end
  end

  defp sentence(:count_must_be_positive), do: "count must be positive"
  defp sentence(:ids_must_not_be_empty), do: "ids must not be empty"
end
