defmodule ExTbpMonty.Objaverse.Glb do
  @moduledoc """
  Reads a binary glTF (`.glb`) into the one thing an object set needs: vertices,
  texture coordinates, triangles and a base-colour texture.

  A GLB is a 12-byte header and two chunks — a JSON document, and the binary
  buffer its accessors index into. What this reads is the subset every
  Sketchfab export in Objaverse uses: triangles (`mode` 4) whose `POSITION` and
  `TEXCOORD_0` are float32 `VEC3`/`VEC2` and whose `indices` are `u16`/`u32`,
  the node tree's transforms, and the material's `baseColorTexture` (an image in
  the binary buffer) or `baseColorFactor`.

  What it deliberately does not read: skins, animations, morph targets, cameras,
  lights, KHR extensions and images addressed by an external `uri`. A mesh comes
  back in its **scene** frame — the node transforms are applied, which is what
  turns the Z-up content Sketchfab stores into the Y-up frame the spec names.

  Texture coordinates come back with V flipped, because OBJ puts its origin at
  the bottom left and glTF at the top left.
  """

  @glb_magic "glTF"
  @json_chunk 0x4E4F534A
  @bin_chunk 0x004E4942

  @float 5126
  @uint32 5125
  @uint16 5123

  @type texture ::
          {:image, binary(), String.t()} | {:colour, {float(), float(), float(), float()}} | :none

  @type mesh :: %{
          vertices: [{float(), float(), float()}],
          uvs: [{float(), float()}] | nil,
          triangles: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}],
          texture: texture()
        }

  @doc "Reads a `.glb` file."
  @spec read_file(Path.t()) :: {:ok, mesh()} | {:error, term()}
  def read_file(path) do
    case File.read(path) do
      {:ok, bytes} -> read(bytes)
      {:error, reason} -> {:error, {:cannot_read, path, reason}}
    end
  end

  @doc "Reads the bytes of a `.glb`."
  @spec read(binary()) :: {:ok, mesh()} | {:error, term()}
  def read(bytes) when is_binary(bytes) do
    with {:ok, document, binary} <- chunks(bytes),
         {:ok, parts} <- scene_parts(document, binary) do
      assemble(parts)
    end
  end

  # -- the container ----------------------------------------------------------

  defp chunks(<<@glb_magic, 2::little-32, _length::little-32, rest::binary>>) do
    with {:ok, json, rest} <- chunk(rest, @json_chunk),
         {:ok, binary, _rest} <- chunk(rest, @bin_chunk) do
      case JSON.decode(json) do
        {:ok, document} when is_map(document) -> {:ok, document, binary}
        {:ok, other} -> {:error, {:not_a_gltf_document, other}}
        {:error, reason} -> {:error, {:invalid_gltf_json, reason}}
      end
    end
  end

  defp chunks(<<magic::binary-size(4), version::little-32, _::binary>>) do
    {:error, {:not_a_binary_gltf, magic, version}}
  end

  defp chunks(_short), do: {:error, :glb_too_short}

  defp chunk(
         <<length::little-32, wanted::little-32, data::binary-size(length), rest::binary>>,
         wanted
       ) do
    {:ok, data, rest}
  end

  # A chunk it did not ask for is skipped rather than refused: the spec allows
  # more than two, and only the JSON and binary ones mean anything here.
  defp chunk(
         <<length::little-32, _other::little-32, _::binary-size(length), rest::binary>>,
         wanted
       ) do
    chunk(rest, wanted)
  end

  defp chunk(<<>>, wanted), do: {:error, {:missing_chunk, wanted}}

  # -- the scene --------------------------------------------------------------

  # Walks the scene from its roots, carrying each node's world matrix, and
  # collects every primitive it meets, already in the scene's frame.
  defp scene_parts(document, binary) do
    scenes = document["scenes"] || []
    scene = Enum.at(scenes, document["scene"] || 0) || %{}
    nodes = document["nodes"] || []

    scene
    |> Map.get("nodes", [])
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, parts} ->
      case walk(document, binary, nodes, index, identity()) do
        {:ok, found} -> {:cont, {:ok, parts ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_mesh_in_scene}
      other -> other
    end
  end

  defp walk(document, binary, nodes, index, matrix) do
    node = Enum.at(nodes, index) || %{}
    world = multiply(matrix, local(node))

    own =
      case node["mesh"] do
        nil ->
          []

        mesh_index ->
          primitives(document, binary, Enum.at(document["meshes"] || [], mesh_index), world)
      end

    node
    |> Map.get("children", [])
    |> Enum.reduce_while({:ok, own}, fn child, {:ok, found} ->
      case walk(document, binary, nodes, child, world) do
        {:ok, more} -> {:cont, {:ok, found ++ more}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp primitives(_document, _binary, nil, _world), do: []

  defp primitives(document, binary, mesh, world) do
    Enum.map(mesh["primitives"] || [], fn primitive ->
      vertices = positions(document, binary, primitive["attributes"]["POSITION"], world)

      %{
        vertices: vertices,
        uvs: uvs(document, binary, primitive["attributes"]["TEXCOORD_0"]),
        triangles: triangles(document, binary, primitive["indices"], length(vertices)),
        texture: texture(document, binary, primitive["material"])
      }
    end)
  end

  # -- accessors --------------------------------------------------------------

  defp positions(_document, _binary, nil, _world), do: []

  defp positions(document, binary, index, world) do
    accessor = accessor(document, index)

    for {x, y, z} <- vectors(document, binary, accessor, 3) do
      apply_matrix(world, x, y, z)
    end
  end

  defp uvs(_document, _binary, nil), do: nil

  defp uvs(document, binary, index) do
    accessor = accessor(document, index)

    for {u, v} <- vectors(document, binary, accessor, 2) do
      # OBJ's origin is the bottom left, glTF's the top left.
      {u, 1.0 - v}
    end
  end

  defp accessor(document, index), do: entry(document["accessors"], index)

  # One entry of one of the document's lists, and an empty map when the list or
  # the index is not there: every reader below asks for a field of it, and a
  # missing field is answered by the default it asks for.
  defp entry(list, index), do: Enum.at(list || [], index) || %{}

  defp vectors(document, binary, accessor, width) do
    view = entry(document["bufferViews"], accessor["bufferView"] || 0)
    offset = (view["byteOffset"] || 0) + (accessor["byteOffset"] || 0)
    stride = if (view["byteStride"] || 0) > 0, do: view["byteStride"], else: width * 4
    count = accessor["count"] || 0

    case accessor["componentType"] do
      @float when width == 3 -> vertices(binary, offset, stride, count)
      @float -> texcoords(binary, offset, stride, count)
      _other -> []
    end
  end

  defp vertices(_binary, _offset, _stride, 0), do: []

  defp vertices(binary, offset, stride, count) do
    for index <- 0..(count - 1) do
      <<x::little-float-32, y::little-float-32, z::little-float-32>> =
        binary_part(binary, offset + index * stride, 12)

      {x, y, z}
    end
  end

  defp texcoords(_binary, _offset, _stride, 0), do: []

  defp texcoords(binary, offset, stride, count) do
    for index <- 0..(count - 1) do
      <<u::little-float-32, v::little-float-32>> = binary_part(binary, offset + index * stride, 8)

      {u, v}
    end
  end

  defp triangles(_document, _binary, nil, vertex_count) do
    if vertex_count < 3,
      do: [],
      else: for(index <- 0..(vertex_count - 1)//3, do: {index, index + 1, index + 2})
  end

  defp triangles(document, binary, index, _vertex_count) do
    accessor = accessor(document, index)
    view = Enum.at(document["bufferViews"] || [], accessor["bufferView"] || 0) || %{}
    offset = (view["byteOffset"] || 0) + (accessor["byteOffset"] || 0)
    count = accessor["count"] || 0

    values =
      case accessor["componentType"] do
        @uint16 -> for <<value::little-16 <- binary_part(binary, offset, count * 2)>>, do: value
        @uint32 -> for <<value::little-32 <- binary_part(binary, offset, count * 4)>>, do: value
        _other -> []
      end

    values |> Enum.chunk_every(3) |> Enum.filter(&(length(&1) == 3)) |> Enum.map(&List.to_tuple/1)
  end

  # -- the material -----------------------------------------------------------

  defp texture(_document, _binary, nil), do: :none

  defp texture(document, binary, material_index) do
    material = Enum.at(document["materials"] || [], material_index) || %{}
    pbr = material["pbrMetallicRoughness"] || %{}

    case pbr["baseColorTexture"] do
      %{"index" => index} -> image(document, binary, index)
      _ -> colour(pbr["baseColorFactor"])
    end
  end

  defp colour([r, g, b, a]), do: {:colour, {r, g, b, a}}
  defp colour([r, g, b]), do: {:colour, {r, g, b, 1.0}}
  defp colour(_none), do: :none

  defp image(document, binary, texture_index) do
    texture = entry(document["textures"], texture_index)
    image = entry(document["images"], texture["source"] || 0)
    view = entry(document["bufferViews"], image["bufferView"] || -1)

    case view["byteLength"] do
      nil ->
        :none

      length ->
        {:image, binary_part(binary, view["byteOffset"] || 0, length),
         image["mimeType"] || "image/png"}
    end
  end

  # -- assembling -------------------------------------------------------------

  # One object is one mesh: the parts are stitched into one vertex list, so a
  # face's indices are shifted by what came before it. A part without texture
  # coordinates leaves the whole answer untextured, because a face cannot carry
  # half a mapping.
  defp assemble(parts) do
    {vertices, uvs, triangles} =
      Enum.reduce(parts, {[], [], []}, fn part, {vertices, uvs, triangles} ->
        shift = length(vertices)

        {vertices ++ part.vertices, uvs ++ (part.uvs || []),
         triangles ++ shifted(part.triangles, shift)}
      end)

    {:ok,
     %{
       vertices: vertices,
       uvs: if(length(uvs) == length(vertices) and uvs != [], do: uvs),
       triangles: triangles,
       texture: Enum.find_value(parts, :none, &(&1.texture != :none && &1.texture))
     }}
  end

  defp shifted(triangles, 0), do: triangles

  defp shifted(triangles, by),
    do: Enum.map(triangles, fn {a, b, c} -> {a + by, b + by, c + by} end)

  # -- transforms -------------------------------------------------------------

  defp identity,
    do: {1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0}

  defp local(node) do
    case node["matrix"] do
      matrix when is_list(matrix) and length(matrix) == 16 ->
        matrix |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()

      _ ->
        trs(node)
    end
  end

  defp trs(node) do
    [tx, ty, tz] = Enum.map(node["translation"] || [0, 0, 0], &(&1 * 1.0))
    [x, y, z, w] = node["rotation"] || [0, 0, 0, 1]
    [sx, sy, sz] = Enum.map(node["scale"] || [1, 1, 1], &(&1 * 1.0))
    {r00, r01, r02, r10, r11, r12, r20, r21, r22} = rotate(x, y, z, w)

    {r00 * sx, r10 * sx, r20 * sx, 0.0, r01 * sy, r11 * sy, r21 * sy, 0.0, r02 * sz, r12 * sz,
     r22 * sz, 0.0, tx, ty, tz, 1.0}
  end

  # The rotation matrix a unit quaternion stands for, column-major like the rest.
  defp rotate(x, y, z, w) do
    xx = x * x
    yy = y * y
    zz = z * z
    xy = x * y
    xz = x * z
    yz = y * z
    wx = w * x
    wy = w * y
    wz = w * z

    {1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 2 * (xy - wz), 1 - 2 * (xx + zz),
     2 * (yz + wx), 2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy)}
  end

  # Column-major, as glTF writes it: element (row, column) is `m[column * 4 + row]`.
  defp multiply(a, b) do
    # Column outer, row inner: the comprehension then lands in column-major order.
    entries = for column <- 0..3, row <- 0..3, do: entry(a, b, row, column)
    List.to_tuple(entries)
  end

  defp entry(a, b, row, column) do
    a0 = elem(a, row)
    a1 = elem(a, 4 + row)
    a2 = elem(a, 8 + row)
    a3 = elem(a, 12 + row)

    a0 * elem(b, column * 4) + a1 * elem(b, column * 4 + 1) + a2 * elem(b, column * 4 + 2) +
      a3 * elem(b, column * 4 + 3)
  end

  defp apply_matrix(matrix, x, y, z) do
    {x * elem(matrix, 0) + y * elem(matrix, 4) + z * elem(matrix, 8) + elem(matrix, 12),
     x * elem(matrix, 1) + y * elem(matrix, 5) + z * elem(matrix, 9) + elem(matrix, 13),
     x * elem(matrix, 2) + y * elem(matrix, 6) + z * elem(matrix, 10) + elem(matrix, 14)}
  end
end
