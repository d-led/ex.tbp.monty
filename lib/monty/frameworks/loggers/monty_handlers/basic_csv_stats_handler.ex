defmodule Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler do
  @moduledoc """
  `tbp/monty/frameworks/loggers/monty_handlers.py::BasicCSVStatsHandler`.

  The file Monty leaves behind after an epoch: one row per learning module per
  episode, appended to `eval_stats.csv` (or `train_stats.csv`), with the columns a
  reader compares held at the front and the header written once per file. An
  existing file is renamed to `_old` rather than appended to, which is Monty's
  `maybe_rename_existing_file` — a run that quietly grew last run's numbers would
  make every comparison after it a guess.

  ## What is filled, and what is not yet

  Monty builds these rows from a stats dictionary its loggers accumulate during
  the episode (`Monty.get_episode_stats`), and this port does not have that
  dictionary yet. So a handler here is given the stats a caller does have and
  writes the columns it names; a column it does not name is written as an empty
  cell rather than guessed at. A blank cell is a fact — "this port did not compute
  it" — where a zero would be a lie that reads like a measurement.

  The column order is Monty's own, so a diff of two files is a diff of values and
  not of layout.
  """

  defstruct path: nil, reported?: false

  @typedoc "A handler bound to one CSV, and whether it has written its header."
  @type t :: %__MODULE__{path: Path.t(), reported?: boolean()}

  # Monty's `BasicCSVStatsHandler.top_columns`, in its order, for the case where
  # the run knows what it believed (the other branch is the same list without the
  # columns about the most likely object).
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

  @doc "The columns, in the order Monty writes them, ending with the module id."
  @spec columns([String.t()]) :: [String.t()]
  def columns(extra_keys \\ []) do
    # A key the named columns already cover is not repeated, however many modules
    # in the episode carry it.
    extra = extra_keys |> Enum.reject(&(&1 in @top_columns or &1 == "lm_id")) |> Enum.uniq()

    @top_columns ++ ["lm_id"] ++ extra
  end

  @doc "The header line for a file whose rows carry these keys."
  @spec header([String.t()]) :: String.t()
  def header(extra_keys \\ []), do: line(columns(extra_keys))

  @doc """
  One row: the module's id and whatever of its stats this run has.

  `stats` is keyed by column name. Anything absent is an empty cell.
  """
  @spec row(String.t() | atom(), map()) :: String.t()
  def row(module_id, stats) do
    stats = Map.new(stats, fn {key, value} -> {to_string(key), value} end)

    stats
    |> Map.keys()
    |> columns()
    |> Enum.map(fn
      "lm_id" -> cell(to_string(module_id))
      key -> cell(Map.get(stats, key))
    end)
    |> line()
  end

  @doc "A handler that reports into `path`."
  @spec new(Path.t()) :: t()
  def new(path) do
    if File.exists?(path), do: rename_existing(path)
    %__MODULE__{path: path}
  end

  @doc """
  Appends one episode's rows, writing the header only for a new file.

  `episode` is a map of learning-module id to that module's stats — Monty's
  `{LM_0: stats, LM_1: stats}` for one episode. Monty counts its writes per file
  (`reports_per_file`) so the header belongs to the first one and nothing is
  renamed after it; the struct carries that state, as everything else here
  carries state in a value.
  """
  # The path is the run's own results directory, chosen when the handler was
  # made, not a name a page hands in.
  # sobelow_skip ["Traversal.FileModule"]
  @spec report(t(), %{optional(String.t() | atom()) => map()}) :: {:ok, t()}
  def report(%__MODULE__{} = handler, episode) do
    rows = Enum.map(episode, fn {module_id, stats} -> row(module_id, stats) end)
    keys = Enum.flat_map(episode, fn {_id, stats} -> Map.keys(stats) end)

    body = Enum.join(rows, "\n") <> "\n"
    content = if handler.reported?, do: body, else: header(keys) <> "\n" <> body

    File.mkdir_p!(Path.dirname(handler.path))
    File.write!(handler.path, content, [:append])

    {:ok, %{handler | reported?: true}}
  end

  @doc "Nothing is held open: a report has written its rows already."
  @spec close(%__MODULE__{}) :: :ok
  def close(%__MODULE__{}), do: :ok

  # `maybe_rename_existing_file`: one `_old`, not a pile of them. The path is
  # the handler's own file, for the same reason as `report/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp rename_existing(path) do
    old = Path.rootname(path) <> "_old" <> Path.extname(path)
    if File.exists?(old), do: File.rm!(old)
    File.rename!(path, old)
  end

  defp line(cells), do: Enum.join(cells, ",")

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: quotable(value)

  defp cell(value) when is_list(value),
    do: value |> Enum.map_join(" ", &to_string/1) |> quotable()

  defp cell(value), do: to_string(value)

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
