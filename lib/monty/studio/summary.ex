defmodule Monty.Studio.Summary do
  @moduledoc """
  What a finished run leaves behind: the numbers a page shows after the last
  timestep, computed from the per-step reports the coordinator produced.

  This is a pure fold over those reports, so "the summary of a run" can be
  tested without starting a process — and so the page, the logs and a future
  result store cannot disagree about what happened.

  The one thing worth calling out is `never_updated`: a learning module that
  never received input during the whole run. It is the failure that looks like
  success — the run finishes, the page is green, and one module did nothing.
  """

  alias Monty.Studio.Setup

  defstruct steps: 0,
            duration_us: 0,
            deadline_hits: 0,
            goals: 0,
            votes_sent: 0,
            votes_used: 0,
            actions: 0,
            inputs: %{},
            never_updated: [],
            sensor_timeouts: []

  @type t :: %__MODULE__{}

  @doc "Folds the per-step reports into one summary."
  @spec from_infos([map()], Setup.t() | nil) :: t()
  def from_infos(infos, setup \\ nil) do
    summary = Enum.reduce(infos, %__MODULE__{}, &add_step/2)

    %{
      summary
      | never_updated: never_updated(summary, setup),
        sensor_timeouts: infos |> Enum.flat_map(&Map.get(&1, :sensor_timeouts, [])) |> Enum.uniq()
    }
  end

  @doc "Average step duration in microseconds, or `nil` for a run with no steps."
  @spec average_step_us(t()) :: float() | nil
  def average_step_us(%__MODULE__{steps: 0}), do: nil

  def average_step_us(%__MODULE__{steps: steps, duration_us: duration_us}),
    do: duration_us / steps

  defp add_step(info, summary) do
    votes = Map.get(info, :votes, %{})

    %{
      summary
      | steps: summary.steps + 1,
        duration_us: summary.duration_us + Map.get(info, :duration_us, 0),
        deadline_hits:
          summary.deadline_hits + if(Map.get(votes, :deadline_hit?, false), do: 1, else: 0),
        goals: summary.goals + Map.get(info, :goals, 0),
        votes_sent: summary.votes_sent + Map.get(votes, :sent, 0),
        votes_used: summary.votes_used + Map.get(votes, :used, 0),
        actions: summary.actions + length(Map.get(info, :actions, [])),
        inputs: merge_counts(summary.inputs, Map.get(info, :inputs, %{}))
    }
  end

  defp merge_counts(total, step) do
    Map.merge(total, step, fn _module, left, right -> left + right end)
  end

  # A learning module that was wired up but never fed is worth saying out loud,
  # and only the configured setup can tell us which modules those were.
  defp never_updated(_summary, nil), do: []

  defp never_updated(summary, %Setup{learning_modules: learning_modules}) do
    for %{id: id} <- learning_modules, Map.get(summary.inputs, id, 0) == 0, do: id
  end
end
