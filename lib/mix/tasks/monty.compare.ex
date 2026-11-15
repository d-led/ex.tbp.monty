defmodule Mix.Tasks.Monty.Compare do
  @shortdoc "Compares runs' eval_stats.csv, episode by episode"

  @moduledoc """
  Puts two runs' episodes side by side:

      mix monty.compare priv/studio_runs/<id>                       # one run, profiled
      mix monty.compare our.csv ../monty-results/eval_stats.csv     # ours against Monty's
      mix monty.compare --labels ours,monty our.csv monty.csv

  A path may be a CSV, a run's folder (the studio keeps one per run), or a
  divided run's folder — the merged `eval_stats.csv` is read when it holds every
  part's episodes, and the parts themselves while the run is still going.

  Each run is profiled: what its learning modules concluded, why its episodes
  ended, whether the target was among the possible matches, and what an episode
  cost in steps, seconds, pose and rotation error. Every run after the first is
  then compared with the first on the episodes the two share, joined on
  `episode_seed`, which both runs take from the experiment's own config. A run
  of twenty episodes against a run of a hundred and forty is a comparison of the
  twenty, and the profile of what the other hundred and twenty did — not an
  error.

  ## Options

    * `--labels NAME,NAME` — what to call each run in the report (default: the
      folder each file is in)
    * `--disagreements N` — how many episodes whose outcome differs to list
      (default: #{20})
    * `--json PATH` — also write the numbers, rather than the report, to PATH
  """

  use Mix.Task

  alias Monty.Studio.EvalStats

  @impl true
  def run(args) do
    {opts, paths} =
      OptionParser.parse!(args, strict: [labels: :string, disagreements: :integer, json: :string])

    if paths == [] do
      Mix.raise("name a run's eval_stats.csv, or a run's folder — see `mix help monty.compare`")
    end

    labels = labels(opts[:labels])

    runs =
      paths
      |> Enum.with_index()
      |> Enum.map(fn {path, index} -> read(path, Enum.at(labels, index)) end)

    runs
    |> EvalStats.report(disagreements: opts[:disagreements] || 20)
    |> IO.iodata_to_binary()
    |> Mix.shell().info()

    if path = opts[:json], do: write_json(path, runs)
  end

  defp read(path, label) do
    EvalStats.read(path, label)
  rescue
    error in [File.Error] ->
      Mix.raise("#{error.path}: #{:file.format_error(error.reason)}")
  end

  defp labels(nil), do: []

  defp labels(text) do
    text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # The numbers a report is written from, for a page or a script that wants
  # them without reading the report back.
  defp write_json(path, runs) do
    report = %{
      "runs" =>
        Enum.map(runs, fn run ->
          %{
            "name" => run.name,
            "path" => run.path,
            "episodes" => EvalStats.episodes(run),
            "files" => run.files,
            "repeated_seeds" => run.duplicates,
            "metrics" => Map.new(EvalStats.metrics(run)),
            "outcome" => EvalStats.outcomes(run),
            "exit" => EvalStats.exits(run),
            "target_found" => EvalStats.targets(run)
          }
        end),
      "comparisons" =>
        case runs do
          [base | rest] ->
            Enum.map(
              rest,
              &%{"base" => base.name, "other" => &1.name, "result" => EvalStats.compare(base, &1)}
            )

          _one_run ->
            []
        end
    }

    File.write!(path, Jason.encode!(report, pretty: true))
    Mix.shell().info("\nwrote #{path}")
  end
end
