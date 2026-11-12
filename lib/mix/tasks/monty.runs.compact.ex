defmodule Mix.Tasks.Monty.Runs.Compact do
  @shortdoc "Moves the pictures a legacy run stored inline into the run's own directory"

  @moduledoc """
  Rewrites the runs whose moments still hold their pictures as bytes.

      mix monty.runs.compact            # what it would do, run by run
      mix monty.runs.compact --apply    # do it

  `--artifacts DIR` says where the pictures are written, which has to be the
  directory the application that serves these runs reads them from:
  `Monty.Paths.artifacts/0` in a desktop build, `priv/studio_runs` in
  development. It defaults to whatever this environment has configured, and the
  task says which one it used before it writes anything — a compaction into the
  wrong directory costs nothing but produces URLs that answer 404.

  A record's moment used to carry the two PNGs a sensor drew, base64 and inline —
  ten kilobytes a step. They live in `frames/<step>/<sensor>-<kind>.png` beside
  the run's log now and the row keeps a URL of forty characters
  (`Monty.Studio.RunHistory.Compaction` has the measurements). Rows written
  before that change still hold the bytes, and every one of them costs what a row
  of that size always costs: a page opening the run decodes it, and on SQLite any
  write to the row rewrites it whole.

  Nothing is lost by running this: each picture is written to disk first, and a
  run is only updated when all of its pictures were written. Running it twice is
  a no-op — a moment that names its pictures has nothing to compact.

  The bytes do not vanish, they move: a file of one studio's, with three runs
  written before the change, gave up **260 MB** of timeline for **115 816
  pictures in 65 MB** on disk (APFS packs small files), and the database went
  from 610 MB to 105 MB once its pages were reclaimed.

  **The file does not shrink by itself.** The bytes are freed inside the database
  and the file keeps its pages; the task says which command reclaims them when it
  is done, and does not run it: `VACUUM` on a file this application is serving is
  a decision, not a maintenance step.
  """

  use Mix.Task

  import Ecto.Query

  alias ExTbpMonty.Repo
  alias Monty.Studio.Artifacts
  alias Monty.Studio.RunHistory.Compaction
  alias Monty.Studio.RunHistory.Run

  @requirements ["app.start"]

  @impl true
  def run(arguments) do
    {options, _rest} =
      OptionParser.parse!(arguments, strict: [apply: :boolean, artifacts: :string])

    apply? = Keyword.get(options, :apply, false)

    case Keyword.fetch(options, :artifacts) do
      {:ok, dir} -> Application.put_env(:ex_tbp_monty, :studio_artifacts_dir, dir)
      :error -> :ok
    end

    runs = candidates()

    Mix.shell().info("database: #{database()}")
    Mix.shell().info("pictures: #{Artifacts.root()}")

    case runs do
      [] ->
        Mix.shell().info("no run holds its pictures inline; nothing to compact")

      _some ->
        reports = Enum.map(runs, &compact(&1, apply?))
        report(reports, apply?)
    end
  end

  defp database do
    case ExTbpMonty.Database.repo_module().__adapter__() do
      Ecto.Adapters.SQLite3 -> ExTbpMonty.Database.sqlite_path()
      _postgres -> "a database server"
    end
  end

  # The rows that still hold a PNG as bytes: every base64 PNG starts with the
  # same eight characters, and asking the database for them keeps a compaction
  # from loading the timelines of runs that have nothing to compact. The cast is
  # how both adapters spell "the document as text" — Postgres renders `jsonb`,
  # SQLite's column already is text.
  defp candidates do
    Run
    |> where([run], like(fragment("CAST(? AS text)", run.timeline), "%iVBOR%"))
    |> Repo.all()
  end

  defp compact(run, false) do
    moments = run.timeline || []
    pictures = Enum.flat_map(moments, &(Compaction.compact(run.id, &1) |> elem(1)))
    compacted = Enum.map(moments, &(Compaction.compact(run.id, &1) |> elem(0)))

    %{
      run: run,
      pictures: length(pictures),
      before_bytes: byte_size(Jason.encode!(moments)),
      after_bytes: byte_size(Jason.encode!(compacted)),
      error: nil
    }
  end

  defp compact(run, true) do
    case Compaction.apply_to(run) do
      {:ok, result} ->
        Map.put(result, :error, nil)

      {:error, reason} ->
        %{run: run, pictures: 0, before_bytes: 0, after_bytes: nil, error: reason}
    end
  end

  defp report(reports, apply?) do
    Enum.each(reports, &report_run/1)

    pictures = Enum.sum(Enum.map(reports, & &1.pictures))
    freed = Enum.sum(Enum.map(reports, &(&1.before_bytes - (&1.after_bytes || &1.before_bytes))))

    Mix.shell().info(
      "\n#{length(reports)} run(s), #{pictures} picture(s), #{megabytes(freed)} of timeline " <>
        if(apply?, do: "rewritten", else: "would be rewritten")
    )

    if apply? and freed > 0, do: say_how_to_reclaim()

    case Enum.filter(reports, & &1.error) do
      [] ->
        :ok

      failed ->
        Mix.raise("#{length(failed)} run(s) could not be compacted; their records are unchanged")
    end
  end

  defp report_run(%{run: run, error: nil} = report) do
    Mix.shell().info(
      "#{run.id} #{run.steps_done} steps: #{megabytes(report.before_bytes)} → " <>
        "#{megabytes(report.after_bytes || report.before_bytes)} · #{report.pictures} picture(s)"
    )
  end

  defp report_run(%{run: run, error: reason}) do
    Mix.shell().error("#{run.id}: left as it was — #{inspect(reason)}")
  end

  # The bytes are free inside the database once the row is rewritten; the file
  # keeps the pages, and only a vacuum gives them back. Which one is the adapter's
  # answer rather than a guess.
  defp say_how_to_reclaim do
    case ExTbpMonty.Database.repo_module().__adapter__() do
      Ecto.Adapters.SQLite3 ->
        Mix.shell().info(
          "The freed pages are still in the file. Reclaim them with:\n" <>
            "  sqlite3 #{ExTbpMonty.Database.sqlite_path()} VACUUM"
        )

      _postgres ->
        Mix.shell().info(
          "The freed rows are still on disk. Reclaim them with:\n  VACUUM FULL studio_runs"
        )
    end
  end

  defp megabytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp megabytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} kB"
  defp megabytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
