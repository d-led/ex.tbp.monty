defmodule ExTbpMonty.Objaverse.GlbTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Objaverse.Glb

  # A GLB assembled from an explicit document and buffer, so each case states the
  # structure it is about rather than depending on a writer's choices.
  defp glb(document, binary) do
    json = pad(JSON.encode!(document), 0x20)
    bin = pad(binary, 0x00)
    total = 12 + 8 + byte_size(json) + 8 + byte_size(bin)

    <<
      "glTF",
      2::little-32,
      total::little-32,
      byte_size(json)::little-32,
      0x4E4F534A::little-32,
      json::binary,
      byte_size(bin)::little-32,
      0x004E4942::little-32,
      bin::binary
    >>
  end

  defp pad(binary, byte) do
    case rem(byte_size(binary), 4) do
      0 -> binary
      rest -> binary <> :binary.copy(<<byte>>, 4 - rest)
    end
  end

  # Three vertices, their texture coordinates, and one triangle, all in one
  # buffer, plus the document that names them.
  defp triangle_document(texture) do
    %{
      "scene" => 0,
      "scenes" => [%{"nodes" => [0]}],
      "nodes" => [
        %{"children" => [1], "matrix" => translation(1.0, 2.0, 3.0)},
        %{"mesh" => 0, "matrix" => scale(2.0)}
      ],
      "meshes" => [
        %{
          "primitives" => [
            %{
              "attributes" => %{"POSITION" => 0, "TEXCOORD_0" => 1},
              "indices" => 2,
              "material" => 0
            }
          ]
        }
      ],
      "materials" => [%{"pbrMetallicRoughness" => texture}],
      "accessors" => [
        %{"bufferView" => 0, "componentType" => 5126, "count" => 3, "type" => "VEC3"},
        %{"bufferView" => 1, "componentType" => 5126, "count" => 3, "type" => "VEC2"},
        %{"bufferView" => 2, "componentType" => 5123, "count" => 3, "type" => "SCALAR"}
      ],
      "bufferViews" => [
        %{"byteOffset" => 0, "byteLength" => 36},
        %{"byteOffset" => 36, "byteLength" => 24},
        %{"byteOffset" => 60, "byteLength" => 6}
      ],
      "buffers" => [%{"byteLength" => 66}]
    }
  end

  defp translation(x, y, z),
    do: [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, x, y, z, 1.0]

  defp scale(s), do: [s, 0.0, 0.0, 0.0, 0.0, s, 0.0, 0.0, 0.0, 0.0, s, 0.0, 0.0, 0.0, 0.0, 1.0]

  defp triangle_buffer do
    positions =
      <<0.0::little-float-32, 0.0::little-float-32, 0.0::little-float-32, 1.0::little-float-32,
        0.0::little-float-32, 0.0::little-float-32, 0.0::little-float-32, 2.0::little-float-32,
        0.0::little-float-32>>

    uvs =
      <<0.0::little-float-32, 0.0::little-float-32, 1.0::little-float-32, 0.0::little-float-32,
        0.0::little-float-32, 1.0::little-float-32>>

    indices = <<0::little-16, 1::little-16, 2::little-16>>
    positions <> uvs <> indices
  end

  describe "the mesh a GLB holds" do
    test "its node transforms are applied, so the vertices are in the scene's frame" do
      bytes =
        glb(triangle_document(%{"baseColorFactor" => [1.0, 0.5, 0.25, 1.0]}), triangle_buffer())

      assert {:ok, mesh} = Glb.read(bytes)

      # The parent translates by (1, 2, 3) and the child scales by 2, so both
      # transforms are in the answer: scale first, then the parent's translation.
      assert mesh.vertices == [{1.0, 2.0, 3.0}, {3.0, 2.0, 3.0}, {1.0, 6.0, 3.0}]
      assert mesh.triangles == [{0, 1, 2}]
    end

    test "its texture coordinates are flipped for OBJ, where the origin is bottom left" do
      bytes =
        glb(triangle_document(%{"baseColorFactor" => [1.0, 1.0, 1.0, 1.0]}), triangle_buffer())

      assert {:ok, mesh} = Glb.read(bytes)

      # glTF (0, 0) is top left; OBJ (0, 0) is bottom left, so v becomes 1 - v.
      assert mesh.uvs == [{0.0, 1.0}, {1.0, 1.0}, {0.0, 0.0}]
    end

    test "an untextured material answers its base colour" do
      bytes =
        glb(triangle_document(%{"baseColorFactor" => [0.2, 0.4, 0.6, 1.0]}), triangle_buffer())

      assert {:ok, %{texture: {:colour, {0.2, 0.4, 0.6, 1.0}}}} = Glb.read(bytes)
    end

    test "a texture is the image bytes the binary buffer holds, with their type" do
      png = <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13>>

      document =
        triangle_document(%{"baseColorTexture" => %{"index" => 0}})
        |> put_in(["textures"], [%{"source" => 0}])
        |> put_in(["images"], [%{"bufferView" => 3, "mimeType" => "image/jpeg"}])
        |> put_in(
          ["bufferViews"],
          triangle_document(%{})["bufferViews"] ++
            [%{"byteOffset" => 66, "byteLength" => byte_size(png)}]
        )

      bytes = glb(document, triangle_buffer() <> png)

      assert {:ok, %{texture: {:image, ^png, "image/jpeg"}}} = Glb.read(bytes)
    end
  end

  describe "what it refuses" do
    test "bytes that are not a binary glTF" do
      assert {:error, {:not_a_binary_gltf, "PK\x03\x04", 20}} =
               Glb.read("PK\x03\x04" <> <<20::little-32>> <> "rest")
    end

    test "a document whose scene holds no mesh" do
      document = %{"scene" => 0, "scenes" => [%{"nodes" => []}], "nodes" => []}
      assert {:error, :no_mesh_in_scene} = Glb.read(glb(document, <<>>))
    end
  end
end
