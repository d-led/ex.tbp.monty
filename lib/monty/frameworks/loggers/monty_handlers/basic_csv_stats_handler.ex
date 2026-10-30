defmodule Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler do
  @moduledoc """
  `tbp/monty/frameworks/loggers/monty_handlers.py::BasicCSVStatsHandler`.

  The file Monty leaves behind after an episode: one row per learning module,
  appended to `train_stats.csv` or `eval_stats.csv`, with the columns a reader
  compares held at the front and the header written once per file. An existing
  file is renamed to `_old` rather than appended to, which is Monty's
  `maybe_rename_existing_file` — a run that quietly grew the last run's numbers
  would make every comparison after it a guess.

  ## The shape of a report

  Monty hands a handler the log dictionary its loggers accumulate, not a
  preformatted table:

      %{"BASIC" => %{"train_stats" => %{0 => %{"LM_0" => stats, "SM_0" => stats}}}}

  Only the `LM_*` components become rows (`lm_stats_to_dataframe` filters exactly
  that way), the file is named from the mode, and `lm_id` is the row's own
  component id. `Monty.Frameworks.Loggers.GraphMatchingLoggers` is what fills the
  dictionary in Monty; until it is ported, a caller — or a test — passes the
  dictionary itself.

  A column the episode does not carry is written as an empty cell rather than
  guessed at: a blank cell is a fact — "this run did not compute it" — where a
  zero would be a measurement nobody made.

  The column order is Monty's own, so a diff of two files is a diff of values and
  not of layout, and a cell is written the way pandas writes it (`1.5`, `True`,
  `[0.1, 0.2]`), so a file from here and a file from Monty are comparable.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode
  alias Monty.Frameworks.Loggers.MontyHandlers.MontyHandler
  alias Monty.Frameworks.Utils.LoggingUtils

  @behaviour MontyHandler

  defstruct reports_per_file: %{}

  @typedoc "Monty's `reports_per_file`: how many reports each output file has had."
  @type t :: %__MODULE__{reports_per_file: %{optional(Path.t()) => non_neg_integer()}}

  # Monty's `BasicCSVStatsHandler.top_columns`, in its order, for the case where
  # the run knows what it believed.
  @top_columns [
    "primary_performance",
    "stepwise_performance",
    "num_steps",
    "rotation_error",
    "result",
    "most_likely_object",
    "primary_target_object",
    "stepwise_target_object",
    "highest_evidence",
    "time",
    "symmetry_evidence",
    "monty_steps",
    "monty_matching_steps",
    "individual_ts_performance",
    "individual_ts_reached_at_step",
    "primary_target_position",
    "primary_target_rotation_euler",
    "most_likely_rotation"
  ]

  # The other branch: the same list without the columns about the most likely
  # object, which a run that never formed a hypothesis does not have.
  @top_columns_without_object [
    "primary_performance",
    "stepwise_performance",
    "num_steps",
    "rotation_error",
    "result",
    "primary_target_object",
    "stepwise_target_object",
    "time",
    "symmetry_evidence",
    "monty_steps",
    "monty_matching_steps",
    "primary_target_position",
    "primary_target_rotation_euler"
  ]

  @doc "`MontyHandler.log_level/0`: this handler filters out the BASIC stats."
  @impl MontyHandler
  @spec log_level() :: :basic
  def log_level, do: :basic

  @doc "A handler that has not written anything yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The columns, in the order Monty writes them, with the module id last."
  @spec columns([{String.t(), map()}]) :: [String.t()]
  def columns(rows) do
    present =
      rows
      |> Enum.flat_map(fn {_id, stats} -> Enum.map(Map.keys(stats), &to_string/1) end)
      |> Enum.uniq()

    named =
      if "most_likely_object" in present, do: @top_columns, else: @top_columns_without_object

    named ++ Enum.reject(present, &(&1 in named or &1 == "lm_id")) ++ ["lm_id"]
  end

  @doc "The header line for a file whose rows carry these stats."
  @spec header([{String.t(), map()}]) :: String.t()
  def header(rows), do: line(columns(rows))

  @doc """
  One row: the module's id and whatever of its stats this run has.

  `stats` is keyed by column name. Anything absent is an empty cell.
  """
  @spec row(String.t(), map()) :: String.t()
  def row(module_id, stats), do: row(module_id, stats, columns([{module_id, stats}]))

  @doc "One row, in the columns already worked out for the file."
  @spec row(String.t(), map(), [String.t()]) :: String.t()
  def row(module_id, stats, columns) do
    stats = Map.new(stats, fn {key, value} -> {to_string(key), value} end)

    columns
    |> Enum.map(fn
      "lm_id" -> cell(module_id)
      column -> cell(Map.get(stats, column))
    end)
    |> line()
  end

  @doc """
  Writes one episode's rows into `<output_dir>/<mode>_stats.csv`.

  `data` is Monty's log dictionary — `%{"BASIC" => %{"train_stats" => ...}}` —
  and `episode` is the local episode number, which Monty takes and does not use
  for the CSV: one file holds every episode, which is why the header belongs to
  the first write only. Monty counts its writes per file (`reports_per_file`), so
  a handler that wrote `train_stats.csv` and is then asked for `eval_stats.csv`
  starts each file properly; the struct carries that state, as everything else
  here carries state in a value.
  """
  # The path is the run's own results directory plus the mode's file name, and
  # the mode is a two-value atom, so nothing here can leave that directory.
  # sobelow_skip ["Traversal.FileModule"]
  @impl MontyHandler
  @spec report_episode(t(), map(), Path.t(), non_neg_integer(), ExperimentMode.t(), map()) ::
          {:ok, t()}
  def report_episode(
        %__MODULE__{} = handler,
        data,
        output_dir,
        _episode,
        mode,
        _episodes_to_total
      ) do
    path = Path.join(output_dir, "#{ExperimentMode.to_string(mode)}_stats.csv")
    {handler, first?} = count_report(handler, path)

    rows = data |> stats(mode) |> rows()
    columns = columns(rows)
    body = Enum.map_join(rows, fn {id, lm_stats} -> row(id, lm_stats, columns) <> "\n" end)

    File.mkdir_p!(output_dir)
    File.write!(path, if(first?, do: line(columns) <> "\n" <> body, else: body), [:append])

    {:ok, handler}
  end

  @doc "Nothing is held open: a report has written its rows already."
  @impl MontyHandler
  @spec close(t()) :: :ok
  def close(%__MODULE__{}), do: :ok

  # The BASIC logs for this mode, in Monty's shape: episode -> component -> stats.
  defp stats(data, mode) do
    data
    |> Map.get("BASIC", %{})
    |> Map.get("#{ExperimentMode.to_string(mode)}_stats", %{})
  end

  # `lm_stats_to_dataframe`: only the learning modules become rows. A sensor
  # module's stats are not a row in the file a reader compares.
  defp rows(stats) do
    for {_episode, components} <- stats,
        {component_id, lm_stats} <- components,
        is_binary(component_id) and String.starts_with?(component_id, "LM_"),
        do: {component_id, lm_stats}
  end

  # `maybe_rename_existing_file` on the first report for a file, and the count
  # every report after it: a file that already exists belongs to the last run.
  # sobelow_skip ["Traversal.FileModule"]
  defp count_report(handler, path) do
    case Map.fetch(handler.reports_per_file, path) do
      :error ->
        :ok = LoggingUtils.maybe_rename_existing_file(path)

        {%{handler | reports_per_file: Map.put(handler.reports_per_file, path, 0)}, true}

      {:ok, reports} ->
        {%{handler | reports_per_file: Map.put(handler.reports_per_file, path, reports + 1)},
         false}
    end
  end

  defp line(cells), do: Enum.join(cells, ",")

  # A cell is written the way pandas writes it, so a file from here and a file
  # from Monty can be diffed: an absent value is empty, a boolean is `True`, a
  # list is `[0.1, 0.2]` with single quotes around its strings.
  defp cell(nil), do: ""
  defp cell(true), do: "True"
  defp cell(false), do: "False"
  defp cell(value) when is_binary(value), do: quotable(value)
  defp cell(value) when is_list(value), do: value |> python() |> quotable()
  defp cell(value) when is_integer(value), do: Integer.to_string(value)
  defp cell(value) when is_float(value), do: to_string(value)
  defp cell(value) when is_atom(value), do: Atom.to_string(value)
  defp cell(value), do: value |> inspect() |> quotable()

  defp python(value) when is_binary(value), do: "'" <> String.replace(value, "'", "\\'") <> "'"
  defp python(nil), do: "None"
  defp python(true), do: "True"
  defp python(false), do: "False"
  defp python(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &python/1) <> "]"
  defp python(value), do: to_string(value)

  # A cell holding a comma, a quote or a newline is quoted, the way a CSV is; a
  # plain one is not, because quoting everything would make a diff noisy.
  defp quotable(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end
