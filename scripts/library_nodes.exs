# How many nodes each object in a library holds — what "dense enough to match"
# means, measured on the libraries this checkout has.
#
#   MIX_ENV=test mix run --no-start /tmp/library_nodes.exs "$MONTY_LIBRARIES/trained"

for dir <- System.argv() do
  for file <- Path.wildcard(Path.join(dir, "*.jsonl.gz")) do
    body = file |> File.read!() |> :zlib.gunzip()

    rows =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.group_by(& &1["object_id"])

    nodes = rows |> Enum.map(fn {id, records} -> {id, Enum.sum(Enum.map(records, &length(&1["positions"])))} end)

    IO.puts("#{Path.basename(file)}: #{map_size(rows)} object(s), #{Enum.sum(Enum.map(nodes, &elem(&1, 1)))} nodes")

    for {id, count} <- Enum.sort_by(nodes, &elem(&1, 1), :desc) do
      features = rows |> Map.fetch!(id) |> hd() |> Map.fetch!("features") |> Map.keys()
      IO.puts("  #{id}: #{count} nodes, features #{Enum.join(Enum.sort(features), " ")}")
    end
  end
end
