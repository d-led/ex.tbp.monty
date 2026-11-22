defmodule Monty.Studio.StepShape do
  @moduledoc """
  What a step's numbers are a measurement of.

  A step's line splits into `sensors`, `await`, `modules`, `round` (with its own
  parts) and `motor`. Two of those are the wall clock of a *round* rather than the
  sum of what ran inside it — five sensors stepped at the same time cost the
  slowest of them, and the modules have always been a round of blocking calls
  where the slowest decides — so the same line means two different things
  depending on how the run was shaped.

  A page that shows the line without saying which shape produced it leaves the
  reader to infer it from the numbers, and the inference is wrong in the direction
  that matters: a concurrent run looks like a faster *machine*, not like a run
  that spent less wall time. So the shapes a reader has to know are said beside
  the log, in the words of the numbers they explain.

  The answer is a list of sentences, empty for Monty's own shape, and it is a
  pure function of the inputs a run's record keeps (`Monty.Studio.RunLog`).
  """

  @type inputs :: %{optional(String.t()) => term()}

  @doc """
  The sentences a reader of this run's step lines needs.

  Empty when the run is Monty's own shape: one sensor after another, a barrier of
  modules, no settle window.
  """
  @spec sentences(inputs()) :: [String.t()]
  def sentences(inputs) when is_map(inputs) do
    sensors_sentence(inputs) ++ modules_sentence(inputs)
  end

  # `sensors_step` is only recorded when the caller *chose* it, so `:auto` is
  # stated as the rule it is rather than as an answer. The rule is Monty's: a
  # step asks its sensors in turn, and the round this port offers is named.
  defp sensors_sentence(inputs) do
    if sensor_count(inputs) > 1, do: served_sensor_sentence(inputs), else: []
  end

  defp served_sensor_sentence(inputs) do
    case Map.get(inputs, "sensors_step") do
      "concurrent" ->
        [
          "Sensors: all at once — `sensors` is the slowest of them, not their sum. " <>
            "A round is not taken over a sensor that draws from the episode's stream, " <>
            "which steps them one at a time again."
        ]

      "serial" ->
        ["Sensors: one after another — `sensors` is their sum."]

      _auto ->
        [
          "Sensors: one after another, as Monty steps them — `sensors` is their sum. " <>
            "`concurrent` asks them all at once instead."
        ]
    end
  end

  # A run whose modules were a step behind is the one place where a step's
  # `receive` and `settle` are about a different epoch from the one it applies
  # (`docs/monty-differences.md` §2.30), and a reader comparing those numbers with
  # a barrier run's is comparing two different questions.
  defp modules_sentence(inputs) do
    case Map.get(inputs, "scheduling") do
      setting when setting in ["one_step_behind", "lagged"] ->
        [
          "Modules: a step behind — a step's `receive` and `settle` belong to the epoch " <>
            "before it, and `await` is not waited for at all."
        ]

      _monty_order ->
        []
    end
  end

  defp sensor_count(inputs) do
    case Map.get(inputs, "sensors") do
      sensors when is_list(sensors) -> length(sensors)
      _unrecorded -> 0
    end
  end
end
