defmodule Mix.Tasks.Monty.Objaverse.Import do
  @shortdoc "Turns a corpus manifest's GLBs into a MuJoCo object set"

  @moduledoc """
  Writes the object set the world reads, from the GLBs a manifest names:

      mix monty.objaverse.import                     # the dogs, from the cache
      mix monty.objaverse.import --download          # fetch what is missing first
      mix monty.objaverse.import --only puppy,milka  # some of them

  A manifest is a JSON file with an `objects` list; each object names its `id`
  (the directory the world will use), its Objaverse `uid` and `shard`, and the
  attribution — `name`, `author`, `licence`, `page`. A set's manifest sits beside
  the configs that step it, `priv/monty_experiments/sets/<set>/<corpus>.json`,
  and the default is the dogs corpus.

  GLBs are cached under `$MONTY_DATA/downloads/<corpus>`, one file per object,
  and fetched from `https://huggingface.co/datasets/allenai/objaverse` only when
  `--download` says so: a corpus is fetched deliberately, never by a build, a
  test or a page load. The set is written under
  `$MONTY_DATA/mujoco/objects/<corpus>`.
  """

  use Mix.Task

  alias ExTbpMonty.Objaverse.{Corpus, Import}

  @switches [manifest: :string, from: :string, into: :string, download: :boolean, only: :string]

  @manifest "priv/monty_experiments/sets/dogs/objaverse_dogs.json"
  @glb "https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs"

  @impl true
  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: @switches)

    manifest = options[:manifest] || @manifest
    corpus = manifest |> Path.basename(".json")
    data = Monty.Prerequisites.root_path("MONTY_DATA")
    from = options[:from] || Path.join([data, "downloads", corpus])
    into = options[:into] || Path.join([data, "mujoco", "objects", corpus])

    objects =
      manifest
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("objects")
      |> only(options[:only])

    File.mkdir_p!(from)

    if options[:download], do: download(objects, from)

    case Import.import(from, objects, into) do
      {:ok, rows} ->
        Mix.shell().info("objaverse: #{length(rows)} object(s) in #{into}")

        Enum.each(rows, fn row ->
          {x, y, z} = row.size

          Mix.shell().info(
            "  #{row.id} — #{row.faces} faces, #{row.vertices} vertices, " <>
              "#{Float.round(x, 3)} × #{Float.round(y, 3)} × #{Float.round(z, 3)} m" <>
              if(row.textured, do: "", else: " — NO TEXTURE (a flat grey patch)")
          )
        end)

        say_comparable(rows)

      {:error, reason} ->
        Mix.raise("objaverse: nothing imported — #{inspect(reason)}")
    end
  end

  # One number a person reads before trusting a corpus: a patch sees the same
  # area of every object, so an object whose footprint is twice another's is
  # covered a quarter as well, and its graph collects a quarter of the nodes —
  # recognition over the corpus then ranks graph density, not shape
  # (`ExTbpMonty.Objaverse.Corpus`). Naming the outliers is the point of the
  # line: an unbalanced corpus is a corpus to fix, not a corpus to run.
  defp say_comparable(rows) do
    report = Corpus.report(rows)
    {widest_id, widest} = report.widest
    {narrowest_id, narrowest} = report.narrowest

    spread =
      "footprints #{Float.round(narrowest, 3)} … #{Float.round(widest, 3)} m " <>
        "(#{Float.round(report.spread, 1)}× the median)"

    if Corpus.comparable?(report) do
      Mix.shell().info("  corpus: #{spread} — comparable")
    else
      Mix.shell().info(
        "  corpus: #{spread} — NOT comparable, the patch covers them unequally: " <>
          "#{Enum.join(report.outliers, ", ")} " <>
          "(#{narrowest_id} #{Float.round(narrowest, 3)} m, #{widest_id} #{Float.round(widest, 3)} m)"
      )
    end
  end

  defp only(objects, nil), do: objects

  defp only(objects, ids) do
    wanted = ids |> String.split(",", trim: true) |> MapSet.new()
    Enum.filter(objects, &MapSet.member?(wanted, &1["id"]))
  end

  defp download(objects, into) do
    {:ok, _} = Application.ensure_all_started(:req)

    Enum.each(objects, fn object ->
      path = Path.join(into, object["uid"] <> ".glb")

      unless File.exists?(path) do
        url = Enum.join([@glb, object["shard"], object["uid"] <> ".glb"], "/")
        Mix.shell().info("objaverse: fetching #{object["name"]}")

        case Req.get(url,
               decode_body: false,
               retry: :transient,
               max_retries: 2,
               receive_timeout: 120_000
             ) do
          {:ok, %{status: 200, body: body}} -> File.write!(path, body)
          {:ok, %{status: status}} -> Mix.raise("objaverse: #{url} answered #{status}")
          {:error, reason} -> Mix.raise("objaverse: #{url} failed — #{inspect(reason)}")
        end
      end
    end)
  end
end
