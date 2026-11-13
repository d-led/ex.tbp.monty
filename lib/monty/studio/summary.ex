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

  `outcome` is the other thing a finished run owes a reader: what the last step
  concluded. It is the model's own terminal states — `:match`, `:no_match`,
  `:time_out`, or `nil` for a module that never answered — because a run that
  stopped after one step and a run that used its whole budget are not the same
  result, and the numbers alone cannot tell them apart.

  `outcomes` is what a run of many episodes owes a reader, which `outcome` cannot
  say: how many episodes each module matched, timed out or called no match. Two
  hundred and sixty-six episodes end in a last episode, and the last episode is
  not the run.
  """

  alias Monty.Studio.Setup

  defstruct steps: 0,
            duration_us: 0,
            world_us: 0,
            deadline_hits: 0,
            goals: 0,
            votes_sent: 0,
            votes_used: 0,
            actions: 0,
            inputs: %{},
            never_updated: [],
            sensor_timeouts: [],
            outcome: %{},
            outcomes: %{}

  @type t :: %__MODULE__{}

  @doc """
  Folds the per-step reports into one summary.

  `conclusion` is the model's final terminal states, which is what a run owes its
  record and which the per-step reports cannot supply: the ending a time-out
  gives an episode happens after the last report. Left out, the last report's
  own terminal states are used.
  """
  @spec from_infos([map()], Setup.t() | nil, map() | nil, keyword()) :: t()
  def from_infos(infos, setup \\ nil, conclusion \\ nil, options \\ []) do
    infos
    |> accrue(%__MODULE__{})
    |> finish(setup, if(is_nil(conclusion), do: outcome(infos), else: conclusion), options)
  end

  @doc """
  Folds an episode's reports into a summary that already holds the run's.

  A run that keeps its reports in order to fold them at the end keeps the whole
  run: 5 110 steps of them measured 4.3 GB on the live node while the ten-object
  config ran, for a summary of a few hundred bytes. `from_infos/4` is this fold
  from zero, so the two cannot disagree about what happened.
  """
  @spec accrue([map()], t()) :: t()
  def accrue(infos, %__MODULE__{} = summary) do
    summary = Enum.reduce(infos, summary, &add_step/2)

    %{summary | sensor_timeouts: Enum.uniq(summary.sensor_timeouts ++ timeouts(infos))}
  end

  @doc """
  The parts of a summary only a finished run knows: the modules that were never
  given anything, what the run concluded, and how often each module concluded it.
  """
  @spec finish(t(), Setup.t() | nil, map(), keyword()) :: t()
  def finish(%__MODULE__{} = summary, setup, outcome, options \\ []) do
    %{
      summary
      | never_updated: never_updated(summary, setup),
        outcome: outcome,
        outcomes: Keyword.get(options, :outcomes, summary.outcomes)
    }
  end

  defp timeouts(infos),
    do: infos |> Enum.flat_map(&Map.get(&1, :sensor_timeouts, [])) |> Enum.uniq()

  @doc """
  Two summaries added, which is what a run of several parts is.

  A parallel run is one experiment in four processes, and the page that shows
  four parts' steps shows one number: everything counted is added, the modules
  that were fed are the modules either part fed, and the episodes each part
  concluded are one tally.

  `finish/4` computes `never_updated` again from the counts this adds up, and a
  part's last step is not the run's, which is why both are left as `finish/4`
  would want them rather than carried over.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = one, %__MODULE__{} = other) do
    %__MODULE__{
      steps: one.steps + other.steps,
      duration_us: one.duration_us + other.duration_us,
      world_us: one.world_us + other.world_us,
      deadline_hits: one.deadline_hits + other.deadline_hits,
      goals: one.goals + other.goals,
      votes_sent: one.votes_sent + other.votes_sent,
      votes_used: one.votes_used + other.votes_used,
      actions: one.actions + other.actions,
      inputs: merge_counts(one.inputs, other.inputs),
      sensor_timeouts: Enum.uniq(one.sensor_timeouts ++ other.sensor_timeouts),
      outcome: %{},
      outcomes: merge_tally(one.outcomes, other.outcomes)
    }
  end

  defp merge_tally(one, other) do
    Map.merge(one, other, fn _module, left, right ->
      Map.merge(left, right, fn _state, count, more -> count + more end)
    end)
  end

  # What the last step concluded. A run with no steps has no outcome, which is
  # not the same as a run whose modules all said nothing.
  defp outcome([]), do: %{}
  defp outcome(infos), do: infos |> List.last() |> Map.get(:terminal_states, %{})

  @doc """
  One episode's conclusion added to the tally of a run's episodes.

  A run of two hundred and sixty-six episodes has two hundred and sixty-six
  conclusions, and the last one is not the run's answer: whether this port
  recognises what Monty recognises is a question about the whole tally.
  `%{module_id => %{outcome => count}}`, with `:match`, `:time_out` and
  `:no_match` among the outcomes a module can have.
  """
  @spec tally(map(), map()) :: map()
  def tally(tally, conclusion) when is_map(conclusion) do
    conclusion
    |> Enum.reject(fn {_module_id, state} -> state in [nil, ""] end)
    |> Enum.reduce(tally, fn {module_id, state}, tally ->
      Map.update(tally, module_id, %{state => 1}, fn per_module ->
        Map.update(per_module, state, 1, &(&1 + 1))
      end)
    end)
  end

  # A conclusion that is not a map is no conclusion — a model that answered
  # nothing at the end of an episode is a case the fold meets, not a case that
  # should take a run down at its boundary.
  def tally(tally, _nothing), do: tally

  @doc """
  The tally in one line: what each module concluded, over how many episodes.

  `learning_module_1: match 61 of 66 · time_out 5` — the number a reader can put
  beside Monty's own, which counts the same episodes.

  A state is read as it is written: `:match` from a running tally, `"match"`
  from the record, which keeps strings because that is what a page and a JSON
  reader both understand. It leads the others in either spelling.
  """
  @spec outcomes_line(map()) :: String.t()
  def outcomes_line(tally) when map_size(tally) == 0, do: "no episodes concluded"

  def outcomes_line(tally) do
    tally
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {module_id, per_module} ->
      total = per_module |> Map.values() |> Enum.sum()

      said =
        per_module
        |> Enum.sort_by(fn {state, _count} -> {not matched?(state), to_string(state)} end)
        |> Enum.map_join(", ", fn {state, count} -> "#{state} #{count}" end)

      "#{module_id}: #{said} of #{total}"
    end)
  end

  defp matched?(state), do: to_string(state) == "match"

  @doc "Average step duration in microseconds, or `nil` for a run with no steps."
  @spec average_step_us(t()) :: float() | nil
  def average_step_us(%__MODULE__{steps: 0}), do: nil

  def average_step_us(%__MODULE__{steps: steps, duration_us: duration_us}),
    do: duration_us / steps

  @doc """
  What the run spent in its own two halves: the model's steps and the world's.

  The wall clock is the run row's (`studio_runs.duration_us`, written when the
  run closes). These are the parts of it that had a clock of their own, and the
  rest — the record, the pictures, the crossing into another language, the
  scheduler — is the wall minus this. A report that shows only one of the three
  cannot tell a slow machine from a slow port, which is what made 772 s of one
  run read as the studio's.

  A step's two clocks are what the step reported, and a world can report a mean
  rather than a whole number of microseconds; the sum is a `number()`, not the
  integer the wall clock beside it is.
  """
  @spec compute_us(t()) :: number()
  def compute_us(%__MODULE__{} = summary), do: summary.duration_us + summary.world_us

  defp add_step(info, summary) do
    votes = Map.get(info, :votes, %{})

    %{
      summary
      | steps: summary.steps + 1,
        duration_us: summary.duration_us + Map.get(info, :duration_us, 0),
        world_us: summary.world_us + Map.get(info, :world_us, 0),
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
