defmodule FlyversePlugin.Pack do
  @moduledoc """
  A connectome pack written from a list of edges, in the shape flyverse reads.

  A pack is four `.npy` arrays — `neuron_ids.npy` (`<u8`), `row_ptr.npy`
  (`<u4`), `destinations.npy` (`<u4`), `signed_counts.npy` (`<i2`) — plus the
  manifest flyverse's own compiler writes. It is a data format, not a library,
  so this module is a writer and `FlyversePlugin.Native.open/1` is the reader,
  and the reader is flyverse's: a pack written here that it refuses is a bug in
  this writer, which is exactly what the test asserts.

  ## Why there is a writer at all

  The dataset is not in any repository: `official-pack` is 150 MB compiled from
  the public Janelia MaleCNS v1.0 release, and flyverse's own README says so
  rather than shipping it. An example that only runs with 150 MB present is an
  example nobody runs, so this writes a four-neuron network with the *same*
  format — which means the code path a laptop exercises is the code path the
  dataset takes, and the difference is the numbers, not the machinery.

  Nothing written here is a result about flies. A four-neuron network whose
  wiring this file states is a statement about the wiring of four neurons.

  ## The plan travels with the pack

  `plan.json` says which model indices a policy drives and which it reads, how
  many ticks a window is, and the seed. Those are facts about the *pack* — the
  real dataset answers them from `male_cns_v1_neural_io.json`, where a group
  name is a list of body IDs and this module's packs name indices directly — so
  they live beside the arrays rather than in the policy.
  """

  @typedoc """
  A network: its body IDs in model order, its signed edges, and its plan.

  An edge is `{from_model_index, to_model_index, signed_contact_count}`, where a
  positive count is an excitatory presynaptic cell and a negative one
  inhibitory. A body ID is any number: the loader uses it for its length.
  """
  @type spec :: %{
          required(:neuron_ids) => [non_neg_integer()],
          required(:edges) => [{non_neg_integer(), non_neg_integer(), integer()}],
          optional(:plan) => map()
        }

  @doc """
  Writes `spec` as a pack in `directory`, creating it if it is not there.

  Answers the directory and the census, so a caller can print what it wrote
  without asking the engine twice.
  """
  @spec write(Path.t(), spec()) :: {:ok, map()} | {:error, String.t()}
  def write(directory, %{neuron_ids: ids, edges: edges} = spec) do
    neuron_count = length(ids)

    with :ok <- valid_edges(edges, neuron_count) do
      {row_ptr, destinations, signed_counts} = source_major(neuron_count, edges)

      File.mkdir_p!(directory)

      write_array(directory, "neuron_ids.npy", "<u8", ids, 8)
      write_array(directory, "row_ptr.npy", "<u4", row_ptr, 4)
      write_array(directory, "destinations.npy", "<u4", destinations, 4)
      write_array(directory, "signed_counts.npy", "<i2", signed_counts, 2)

      File.write!(Path.join(directory, "manifest.json"), manifest(neuron_count, edges))
      File.write!(Path.join(directory, "plan.json"), plan(spec))

      {:ok, %{directory: directory, neurons: neuron_count, edges: length(edges)}}
    end
  end

  def write(_directory, spec) do
    {:error,
     "a pack is written from %{neuron_ids: [...], edges: [...]}, and this is #{inspect(spec)}"}
  end

  @doc """
  The arrays a pack is made of, without writing anything.

  Public because the CSR is the part worth testing on its own: a row of a
  source-major graph has to hold every edge that source has, in one place, in
  the order they were given.
  """
  @spec source_major(non_neg_integer(), [{non_neg_integer(), non_neg_integer(), integer()}]) ::
          {[non_neg_integer()], [non_neg_integer()], [integer()]}
  def source_major(neuron_count, edges) do
    by_source = Enum.group_by(edges, fn {from, _to, _count} -> from end)

    rows =
      for source <- 0..(neuron_count - 1)//1 do
        by_source |> Map.get(source, []) |> Enum.map(fn {_from, to, count} -> {to, count} end)
      end

    destinations = Enum.flat_map(rows, fn row -> Enum.map(row, &elem(&1, 0)) end)
    signed_counts = Enum.flat_map(rows, fn row -> Enum.map(row, &elem(&1, 1)) end)

    # `row_ptr` has one entry per neuron plus the terminal total, which is what
    # makes `row_ptr[n]` the edge count rather than an out-of-range read.
    row_ptr = [0 | Enum.scan(rows, 0, fn row, total -> total + length(row) end)]

    {row_ptr, destinations, signed_counts}
  end

  defp valid_edges(edges, neuron_count) do
    case Enum.find(edges, &out_of_range?(&1, neuron_count)) do
      nil ->
        :ok

      {from, to, _count} ->
        {:error,
         "the edge #{from} -> #{to} names a neuron this pack does not have " <>
           "(it has 0..#{neuron_count - 1})"}
    end
  end

  defp out_of_range?({from, to, _count}, neuron_count),
    do: from < 0 or from >= neuron_count or to < 0 or to >= neuron_count

  # NPY v1.0: magic, two version bytes, a little-endian header length, the
  # header dict, then the payload. The payload has to start on an 8-byte
  # boundary (`Npy::open` refuses otherwise), so the header is padded with
  # spaces before its newline until `10 + header` divides by eight.
  defp write_array(directory, name, descr, elements, width) do
    payload = for element <- elements, into: <<>>, do: <<element::signed-little-size(width * 8)>>

    shape = "(#{length(elements)},)"
    dict = "{'descr': '#{descr}', 'fortran_order': False, 'shape': #{shape}, }"
    padding = :binary.copy(" ", rem(8 - rem(10 + byte_size(dict) + 1, 8), 8))
    header = dict <> padding <> "\n"

    File.write!(
      Path.join(directory, name),
      <<0x93, "NUMPY", 1, 0, byte_size(header)::little-16, header::binary, payload::binary>>
    )
  end

  defp manifest(neuron_count, edges) do
    %{
      "dataset" => "written by flyverse_plugin's Pack writer: not a fly",
      "license" => "none: a network this file's caller stated",
      "counts" => %{"neurons" => neuron_count, "edges" => length(edges)}
    }
    |> Jason.encode!(pretty: true)
  end

  defp plan(%{plan: plan}), do: Jason.encode!(plan, pretty: true)

  defp plan(_spec) do
    Jason.encode!(%{"ticks" => 20, "seed" => 0, "drives" => [], "readouts" => []}, pretty: true)
  end
end
