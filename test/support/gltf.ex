defmodule ExTbpMonty.Test.Gltf do
  @moduledoc """
  Builds a small binary glTF file for tests: one node, one mesh, a triangle index
  buffer, optional texture coordinates, and a material that is a colour or an
  image the binary buffer holds.
  """

  @doc """
  A GLB whose scene is one node with one triangle.

  `opts`:

    * `:vertices` — `[{x, y, z}]`, three by default;
    * `:uvs` — `[{u, v}]` matching the vertices, or `nil` for none;
    * `:texture` — a `pbrMetallicRoughness` map, or `{:image, bytes, mime_type}`;
    * `:node` — the node's map, by default a mesh translated by (1, 2, 3).
  """
  def triangle_glb(opts \\ []) do
    vertices = Keyword.get(opts, :vertices, [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {0.0, 2.0, 0.0}])
    uvs = Keyword.get(opts, :uvs, [{0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}])
    texture = Keyword.get(opts, :texture, %{"baseColorFactor" => [1.0, 1.0, 1.0, 1.0]})
    node = Keyword.get(opts, :node, %{"mesh" => 0, "matrix" => translation(1.0, 2.0, 3.0)})

    parts = parts(vertices, uvs, texture)
    {views, binary} = layout(parts)
    index_of = fn name -> Enum.find_index(parts, fn {part, _bytes} -> part == name end) end

    document =
      %{
        "asset" => %{"version" => "2.0"},
        "scene" => 0,
        "scenes" => [%{"nodes" => [0]}],
        "nodes" => [node],
        "meshes" => [%{"primitives" => [primitive(uvs, index_of)]}],
        "materials" => [%{"pbrMetallicRoughness" => material(texture)}],
        "accessors" => accessors(length(vertices), uvs, index_of),
        "bufferViews" => views,
        "buffers" => [%{"byteLength" => byte_size(binary)}]
      }
      |> Map.merge(images(texture, index_of))

    glb(document, binary)
  end

  defp parts(vertices, uvs, texture) do
    positions = for {x, y, z} <- vertices, into: <<>>, do: float3(x, y, z)
    coordinates = if uvs, do: :binary.list_to_bin(for {u, v} <- uvs, do: float2(u, v))
    indices = for index <- 0..(length(vertices) - 1), into: <<>>, do: <<index::little-16>>

    [{"positions", positions}] ++
      if(uvs, do: [{"uvs", coordinates}], else: []) ++
      [{"indices", indices}] ++
      case texture do
        {:image, bytes, _mime} -> [{"image", bytes}]
        _ -> []
      end
  end

  defp layout(parts) do
    Enum.reduce(parts, {[], <<>>}, fn {_name, bytes}, {views, binary} ->
      {views ++ [%{"byteOffset" => byte_size(binary), "byteLength" => byte_size(bytes)}],
       binary <> bytes}
    end)
  end

  defp primitive(uvs, index_of) do
    attributes = %{"POSITION" => index_of.("positions")}
    attributes = if uvs, do: Map.put(attributes, "TEXCOORD_0", index_of.("uvs")), else: attributes

    %{"attributes" => attributes, "indices" => index_of.("indices"), "material" => 0, "mode" => 4}
  end

  defp accessors(count, uvs, index_of) do
    positions = %{
      "bufferView" => index_of.("positions"),
      "componentType" => 5126,
      "count" => count,
      "type" => "VEC3"
    }

    coordinates =
      if uvs,
        do: [
          %{
            "bufferView" => index_of.("uvs"),
            "componentType" => 5126,
            "count" => count,
            "type" => "VEC2"
          }
        ],
        else: []

    indices = %{
      "bufferView" => index_of.("indices"),
      "componentType" => 5123,
      "count" => count,
      "type" => "SCALAR"
    }

    [positions] ++ coordinates ++ [indices]
  end

  defp material({:image, _bytes, _mime}), do: %{"baseColorTexture" => %{"index" => 0}}
  defp material(pbr), do: pbr

  defp images({:image, _bytes, mime}, index_of) do
    %{
      "textures" => [%{"source" => 0}],
      "images" => [%{"bufferView" => index_of.("image"), "mimeType" => mime}]
    }
  end

  defp images(_pbr, _index_of), do: %{}

  @doc "Assembles a GLB from a decoded document and a binary buffer."
  def glb(document, binary) do
    json = pad(JSON.encode!(document), 0x20)
    bin = pad(binary, 0x00)

    <<
      "glTF",
      2::little-32,
      12 + 8 + byte_size(json) + 8 + byte_size(bin)::little-32,
      byte_size(json)::little-32,
      0x4E4F534A::little-32,
      json::binary,
      byte_size(bin)::little-32,
      0x004E4942::little-32,
      bin::binary
    >>
  end

  defp float3(x, y, z),
    do: <<x * 1.0::little-float-32, y * 1.0::little-float-32, z * 1.0::little-float-32>>

  defp float2(x, y), do: <<x * 1.0::little-float-32, y * 1.0::little-float-32>>

  defp pad(binary, byte) do
    case rem(byte_size(binary), 4) do
      0 -> binary
      rest -> binary <> :binary.copy(<<byte>>, 4 - rest)
    end
  end

  @doc "A column-major translation matrix, as glTF writes it."
  def translation(x, y, z),
    do: [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, x, y, z, 1.0]
end
