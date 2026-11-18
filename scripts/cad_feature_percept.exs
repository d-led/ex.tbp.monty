# What a patch reads on each kind of face a part is made of, and what the
# memory of that part holds.
#
#   mix run scripts/cad_feature_percept.exs priv/cad_experiments/parts/plate.step
#   mix run scripts/cad_feature_percept.exs <part.step> <root>/<release>/<name>.jsonl.gz
#
# A CAD feature run answers which feature the sensor is on, so two things have to
# agree: the surfaces the world presents and the surfaces the memory holds. This
# prints both sides — what patches on a face of each label the recognition found
# read, in the metres a run matches in, and the node counts of the library the
# run loads, split by whether a node is flat.
#
# The percepts come from `MontyCad.Percept`, the framework's own observation
# processor over exact B-rep ray casts: the same processor that taught the
# memory, and the same one a run's sensor uses.
#
# A patch is 4096 rays from a stand-off of five millimetres, so it covers about
# sixteen millimetres of surface — wider than a feature is. Where a patch lands
# therefore decides whether it reads one surface or two, which is why a label is
# reported as a spread over several patches rather than as one number.

defmodule CadFeaturePercept do
  @moduledoc false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Studio.Memory
  alias MontyCad.Percept
  alias Quiddity.{Camera, Face, Frame, Recognition}

  # How far a patch stands off the surface — the CAD teacher's own default.
  @stand_off 5.0
  # How many patches a label is offered. Each one is a frame: 4096 rays.
  @patches_per_label 8
  # A curvature below this reads as flat, in the metres a run measures in.
  @flat 0.05

  def main(argv) do
    [part_path, library_path] = Enum.take(Enum.concat(argv, [nil]), 2)
    part_path = part_path || Path.expand("../priv/cad_experiments/parts/plate.step", __DIR__)

    {:ok, part} = Quiddity.open(part_path)
    {:ok, recognition} = Quiddity.features(part)

    IO.puts("#{Path.basename(part_path)}: what patches on each face read, in metres\n")

    for {label, patches} <- patches_of_each(part, recognition) do
      print_face(label, patches)
    end

    case library_path do
      nil ->
        IO.puts("\nGive a library to read a memory beside the part.")

      path ->
        IO.puts("\n#{Path.basename(path)}: what the memory holds, in metres\n")

        memory = read(path)

        for graph_id <- GraphMemory.get_memory_ids(memory) do
          print_graph(memory, graph_id)
        end
    end
  end

  # Up to @patches_per_label visits on a face of each label, so a face too small
  # to hold a patch whole is seen as it is: sometimes flat, sometimes the two
  # surfaces the patch straddled.
  defp patches_of_each(part, recognition) do
    {:ok, samples} = Quiddity.samples(part, spacing: 1.0, limit: 200_000)

    [samples.points, samples.normals, samples.faces]
    |> Enum.zip()
    |> Enum.group_by(fn {_point, _normal, face} -> label_of(recognition, face) end)
    |> Enum.sort_by(fn {label, _visits} -> label end)
    |> Enum.map(fn {label, visits} ->
      {label, visits |> Enum.take(@patches_per_label) |> Enum.map(&percept(part, label, &1))}
    end)
  end

  defp percept(part, label, {point, normal, face_index}) do
    {:ok, face} = Quiddity.face(part, face_index)
    {:ok, camera} = Camera.patch(point, normal, distance: @stand_off)
    {:ok, frame} = Quiddity.frame(part, camera)
    {:ok, message} = Percept.message(frame, units: :metres)

    %{
      label: label,
      face: face,
      curvatures: message.non_morphological_features["principal_curvatures"],
      inside: share_on(frame, face_index)
    }
  end

  defp print_face(label, patches) do
    face = patches |> List.first() |> Map.fetch!(:face)

    readings = patches |> Enum.map(& &1.curvatures) |> Enum.reject(&is_nil/1)
    flat = Enum.count(readings, fn [first, second] -> flat?(first) and flat?(second) end)

    IO.puts(
      "#{String.pad_trailing(label, 14)} #{String.pad_trailing(Face.describe(face), 40)} " <>
        "patches #{length(patches)}  flat #{flat}  " <>
        "k1 #{spread(readings, 0)}  k2 #{spread(readings, 1)}"
    )
  end

  # The lowest and highest reading a patch made, which says whether a face reads
  # the same way wherever it is patched.
  defp spread([], _which), do: "none"

  defp spread(readings, which) do
    values = readings |> Enum.map(&Enum.at(&1, which)) |> Enum.sort()

    "#{number(List.first(values))} .. #{number(List.last(values))}"
  end

  # The share of the patch's pixels that landed on this one face: a patch wholly
  # inside a face reads that face, and one that is not straddles an edge.
  defp share_on(frame, face_index) do
    case frame |> Frame.face_ids() |> Enum.reject(&is_nil/1) do
      [] -> 0.0
      hits -> Enum.count(hits, &(&1 == face_index)) / length(hits)
    end
  end

  defp label_of(recognition, face) do
    case Recognition.owner(recognition, face) do
      :body -> "body"
      :refused -> "refused"
      :unexplained -> "unexplained"
      id when is_binary(id) -> id
      other -> to_string(other)
    end
  end

  # A library is `<root>/<release>/<name>.jsonl.gz`, which is the address the
  # reader takes.
  defp read(path) do
    {:ok, memory} = Memory.load(name_of(path), release_of(path), root_of(path))

    memory
  end

  defp name_of(path), do: path |> Path.basename() |> String.replace_suffix(".jsonl.gz", "")
  defp release_of(path), do: path |> Path.dirname() |> Path.basename()
  defp root_of(path), do: path |> Path.dirname() |> Path.dirname()

  defp print_graph(memory, graph_id) do
    channel = memory |> GraphMemory.get_input_channels_in_graph(graph_id) |> List.first()
    graph = GraphMemory.get_graph(memory, graph_id, channel)
    nodes = memory.object_model.positions(graph)

    flat =
      graph
      |> memory.object_model.get_values_for_feature("principal_curvatures_log")
      |> Enum.count(fn
        [first, second] -> flat?(first) and flat?(second)
        _none -> false
      end)

    IO.puts(
      "#{String.pad_trailing(graph_id, 16)} nodes #{pad(length(nodes))}  " <>
        "flat #{pad(flat)}  curved #{pad(length(nodes) - flat)}"
    )
  end

  defp pad(text), do: String.pad_leading(to_string(text), 6)

  # `principal_curvatures_log` is signed in the log, so a stored value near zero
  # is the flat reading whatever the units; `principal_curvatures` is metres.
  defp flat?(value), do: abs(value) < @flat

  defp number(nil), do: "none"
  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
end

CadFeaturePercept.main(System.argv())
