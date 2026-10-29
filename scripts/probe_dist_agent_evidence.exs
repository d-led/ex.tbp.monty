# Why episode 1 of Monty's ten does not match — the evidence, step by step.
#
#   MIX_ENV=test mix run scripts/probe_dist_agent_evidence.exs
#
# `scripts/probe_dist_agent_episodes.exs` shows the port does not reach Monty's
# conclusion on the first recorded episode. This narrows it down the way
# `pretrained_replay_test.exs` does for the one episode that does agree: give the
# learning module the recorded percepts one step at a time, and print what it
# holds beside what Monty held.
#
# Where the two first differ is the answer:
#
#   * step 0 already differs -> the memory, the features the export carries, or
#     the tolerances the module was built with;
#   * step 0 agrees and it drifts -> the per-step arithmetic (weights, burst
#     sampling, the hypotheses updater).
#
# Nothing here replaces the episode probe: this one module, no coordinator, no
# world, so it is fast and it isolates the arithmetic.

defmodule Probe do
  def top(evidence) when map_size(evidence) == 0, do: "(no graphs)"

  def top(evidence) do
    evidence
    |> Enum.sort_by(fn {_id, value} -> -value end)
    |> Enum.take(3)
    |> Enum.map_join(" ", fn {id, value} -> "#{id}=#{Float.round(value * 1.0, 3)}" end)
  end

  def row(step, left, right) when is_integer(step) do
    row(step |> Integer.to_string() |> String.pad_leading(2), left, right)
  end

  def row(step, left, right) do
    IO.puts("#{String.pad_trailing(to_string(step), 2)} | #{String.pad_trailing(left, 46)} | #{right}")
  end
end

alias Monty.Context
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"
shown = 8

{:ok, opened} = Monty.Studio.open(experiment)
%{learning_modules: [%{state: lm0}]} = Setup.model_spec(opened.setup, "probe-evidence")

[percepts_per_step | _more] = MontyRecording.episodes!(recording)
monty = MontyRecording.evidence_over_steps!(recording)

Probe.row("st", "Monty (top 3 evidence)", "port (top 3 evidence)")

lm =
  percepts_per_step
  |> Enum.with_index()
  |> Enum.reduce(lm0, fn
    {[], step}, lm ->
      Probe.row(step, "(silent step)", "")
      lm

    {percepts, step}, lm ->
      {:ok, lm} = EvidenceGraphLM.matching_step(percepts, Context.new(0), lm)
      lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
      {lm, _terminal_state} = EvidenceGraphLM.update_terminal_condition(lm)

      {ids, values} = EvidenceGraphLM.evidence_for_each_graph(lm)
      ours = Map.new(Enum.zip(ids, values))

      if step < shown, do: Probe.row(step, Probe.top(Enum.at(monty, step, %{})), Probe.top(ours))

      lm
  end)

IO.puts(
  "\nfinal: port #{inspect(lm.terminal_state)} #{inspect(lm.detected_object)} " <>
    "after #{length(percepts_per_step)} steps"
)
