defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModule do
  @moduledoc """
  How much evidence a hypothesis needs before this step is worth spending on it.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/learning_module.py`,
  whose module-level part is this one decision. The learning module itself is
  `Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM`.

  ## Why a threshold at all

  A step compares the observation against every hypothesis of every object.
  Most of them are hopeless, and testing them costs the same as testing the
  good ones. So a hypothesis is only updated if its evidence is above a
  threshold derived from the *best* hypothesis so far: near the top of the
  field is where a step can still change the answer.

  A hypothesis below the threshold is not deleted — it keeps exactly the
  evidence it had. That matters: an object that looks wrong now can still be
  right later, and Monty's later steps are what make burst sampling worth
  anything.

  ## The settings

    * a **number** — a fixed threshold in evidence units, ignoring the field;
    * `"mean"` / `"median"` — the average or middle of all hypotheses' evidence;
    * `"all"` — the lowest evidence of the field, i.e. update everything. This
      is Monty's default and what the experiments run;
    * `"[n]%"` — the best hypothesis minus `n` per cent of its evidence, so
      "within 5% of the leader";
    * `"x_percent_threshold"` — the same rule using the learning module's
      `x_percent_threshold`, which is the setting Monty's configs actually set.

  The last two are one rule with two spellings, so both parse to
  `{:percent_of_max, percentage}`; the pairing of `"x_percent_threshold"` with
  the module's `x_percent_threshold` happens once, when the config is parsed.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.InvalidEvidenceThresholdConfig

  @typedoc """
  A threshold setting, parsed: the forms above, with the two percentage
  spellings already resolved to one.
  """
  @type config :: number() | :mean | :median | :all | {:percent_of_max, float()}

  @doc """
  Reads a threshold setting, resolving `"x_percent_threshold"` against the
  learning module's own `x_percent_threshold`.

  Parsed once when the learning module is built, because a setting is
  configuration: if it is wrong, the experiment should not start.
  """
  @spec parse_config(term(), number()) ::
          {:ok, config()} | {:error, InvalidEvidenceThresholdConfig.t()}
  def parse_config(config, x_percent_threshold) do
    cond do
      is_number(config) -> {:ok, config}
      config == "mean" -> {:ok, :mean}
      config == "median" -> {:ok, :median}
      config == "all" -> {:ok, :all}
      config == "x_percent_threshold" -> {:ok, {:percent_of_max, x_percent_threshold * 1.0}}
      is_binary(config) -> parse_percentage(config)
      true -> {:error, %InvalidEvidenceThresholdConfig{config: config}}
    end
  end

  defp parse_percentage(config) do
    with true <- String.ends_with?(config, "%"),
         {percentage, ""} <- Float.parse(String.trim_trailing(config, "%")),
         true <- percentage >= 0 and percentage <= 100 do
      {:ok, {:percent_of_max, percentage}}
    else
      _not_a_percentage -> {:error, %InvalidEvidenceThresholdConfig{config: config}}
    end
  end

  @doc """
  The evidence a hypothesis must reach to be updated this step.

  With no evidence at all there is nothing to compare against, so the threshold
  is zero and every hypothesis — there are none — passes it. That case is the
  first step of an episode for every object in memory.
  """
  @spec evidence_update_threshold(config(), number(), [number()]) :: float()
  def evidence_update_threshold(_config, _max_global_evidence, []), do: 0.0

  def evidence_update_threshold(config, _max_global_evidence, _evidence)
      when is_number(config),
      do: config * 1.0

  def evidence_update_threshold(:mean, _max_global_evidence, evidence),
    do: Monty.Math.mean(evidence)

  def evidence_update_threshold(:median, _max_global_evidence, evidence),
    do: median(evidence)

  def evidence_update_threshold(:all, _max_global_evidence, evidence),
    do: Enum.min(evidence)

  def evidence_update_threshold({:percent_of_max, percentage}, max_global_evidence, _evidence),
    do: max_global_evidence - max_global_evidence * (percentage / 100)

  # numpy's median averages the two middle values of an even-sized sample.
  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end
end
