defmodule ExTbpMonty.Objaverse.Import do
  @moduledoc """
  Turns downloaded Objaverse meshes into an object set the MuJoCo world reads.

  The world's contract is four things per object: `textured.obj`,
  `texture_map.png`, an optional `metadata.json` (`refpos`, `refquat`, `scale`)
  and a directory named after the object. A GLB is none of those, so this is the
  letter of the conversion:

    * the glTF frame (Y up) is turned into the world's (Z up);
    * the mesh is written at its own scale, and the placement that matters —
      centred horizontally, sitting on the table, one size for every object — is
      written into `metadata.json`, so the numbers can be read rather than
      reverse-engineered from the vertices;
    * the material's base-colour texture becomes `texture_map.png`, decoded
      through `stb_image` (a JPEG is not a PNG, and MuJoCo is asked for a PNG);
      an untextured material becomes a one-pixel PNG of its colour.

  An entry is refused rather than half-written: a mesh with no faces, or one
  whose GLB is not where the manifest says it is, stops the import and names
  itself. `ATTRIBUTION.md` is written once for the set — the licence record has
  to travel with the data, not stay in a plan.
  """

  alias ExTbpMonty.Objaverse.Glb

  # The world's surface agent rides 10 cm up and its patch clips at 5 cm, so an
  # object shorter than that is only ever half readable — the failure the hand-over
  # records for spoons. A corpus is therefore normalised by **height**, not by its
  # longest side: a dog is long and low, and scaling its length to 10 cm leaves it
  # under the clip.
  @height 0.10
  @default_colour {0.6, 0.6, 0.6}

  @type entry :: %{
          required(String.t()) => String.t(),
          optional(String.t()) => String.t() | nil
        }

  @doc """
  Writes every entry into `into`, reading each GLB from `source`.

  Answers one row per object: its directory name, face count, the scale it was
  given and how many vertices came through.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # `source` and `into` are the two directories `mix monty.objaverse.import`
  # takes on its command line (`--from`, `--into`); an operator names them.
  @spec import(Path.t(), [entry()], Path.t()) :: {:ok, [map()]} | {:error, term()}
  def import(source, entries, into) do
    File.mkdir_p!(into)

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, written} ->
      case one(source, entry, into) do
        {:ok, row} -> {:cont, {:ok, written ++ [row]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} ->
        attribution(into, entries)
        {:ok, rows}

      error ->
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The directories are the ones above; the two names joined onto them are the
  # entry's `uid` and `id`, which are our manifest's own fields — not a
  # request's.
  defp one(source, entry, into) do
    path = Path.join(source, entry["uid"] <> ".glb")
    directory = Path.join(into, entry["id"])

    with {:ok, mesh} <- Glb.read_file(path),
         :ok <- has_faces(mesh),
         {:ok, placement, zup} <- placement(mesh.vertices, entry),
         :ok <- File.mkdir_p(directory),
         :ok <- write_object(Path.join(directory, "textured.obj"), %{mesh | vertices: zup}),
         :ok <- write_texture(Path.join(directory, "texture_map.png"), mesh.texture),
         :ok <- File.write(Path.join(directory, "metadata.json"), JSON.encode!(placement)) do
      {:ok,
       %{
         id: entry["id"],
         uid: entry["uid"],
         faces: length(mesh.triangles),
         vertices: length(mesh.vertices),
         scale: placement["scale"],
         size: size(zup, placement["scale"])
       }}
    else
      {:error, reason} -> {:error, {:cannot_import, entry["id"] || entry["uid"], reason}}
    end
  end

  defp has_faces(%{triangles: []}), do: {:error, :no_faces}
  defp has_faces(_mesh), do: :ok

  # Where the object sits and how big it is, in the world's frame: the glTF Y-up
  # frame turned Z-up, centred on its own footprint, resting on z = 0, and scaled
  # to one height for the whole corpus. A flat object (a height of nought) falls
  # back to its longest side, which is the only dimension it has.
  defp placement(vertices, _entry) do
    zup = Enum.map(vertices, fn {x, y, z} -> {x, -z, y} end)
    {min_x, max_x, min_y, max_y, min_z, max_z} = bounds(zup)

    longest = Enum.max([max_x - min_x, max_y - min_y, max_z - min_z])
    height = max_z - min_z
    by = if height > longest / 3, do: height, else: longest

    if by <= 0 do
      {:error, :degenerate_mesh}
    else
      scale = @height / by

      {:ok,
       %{
         "refpos" => [
           rounded((min_x + max_x) / 2),
           rounded((min_y + max_y) / 2),
           rounded(min_z)
         ],
         "refquat" => [1.0, 0.0, 0.0, 0.0],
         "scale" => [scale, scale, scale]
       }, zup}
    end
  end

  defp rounded(value), do: Float.round(value, 6)

  # What the world will see, in metres: the vertex extents times the metadata
  # scale. This is the number that says whether the object is tall enough for the
  # patch's 5 cm clip, so it is reported by the import rather than left to a
  # person re-deriving it from a JSON file.
  defp size(vertices, [scale | _rest]) do
    {min_x, max_x, min_y, max_y, min_z, max_z} = bounds(vertices)

    {rounded((max_x - min_x) * scale), rounded((max_y - min_y) * scale),
     rounded((max_z - min_z) * scale)}
  end

  # The bounds start at the first vertex, not at zero: a scan centred a metre from
  # the origin was being reported as if it began there.
  defp bounds([{x, y, z} | rest]) do
    Enum.reduce(rest, {x, x, y, y, z, z}, fn {vx, vy, vz}, {x0, x1, y0, y1, z0, z1} ->
      {min(x0, vx), max(x1, vx), min(y0, vy), max(y1, vy), min(z0, vz), max(z1, vz)}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `path` is the object's directory above with a fixed file name.
  defp write_object(path, mesh) do
    vertices =
      Enum.map(mesh.vertices, fn {x, y, z} ->
        ["v ", format(x), " ", format(y), " ", format(z), "\n"]
      end)

    uvs =
      case mesh.uvs do
        nil -> []
        uvs -> Enum.map(uvs, fn {u, v} -> ["vt ", format(u), " ", format(v), "\n"] end)
      end

    faces =
      Enum.map(mesh.triangles, fn {a, b, c} ->
        if mesh.uvs,
          do: ["f ", face(a), " ", face(b), " ", face(c), "\n"],
          else: ["f ", index(a), " ", index(b), " ", index(c), "\n"]
      end)

    File.write(path, [vertices, uvs, faces])
  end

  defp face(index), do: [index(index), "/", index(index), "/", index(index)]

  defp index(position), do: Integer.to_string(position + 1)

  # Six decimals is a micrometre at the scale these objects are placed at, and it
  # keeps the file free of exponent notation some OBJ readers refuse.
  defp format(value), do: :io_lib.format("~.6f", [value * 1.0])

  defp write_texture(path, {:image, bytes, _mime}) do
    case StbImage.read_binary(bytes) do
      {:ok, image} -> StbImage.write_file(image, path)
      {:error, reason} -> {:error, {:cannot_read_texture, reason}}
    end
  end

  defp write_texture(path, {:colour, {r, g, b, _a}}) do
    pixel = <<channel(r), channel(g), channel(b)>>

    pixel
    |> StbImage.new({1, 1, 3})
    |> StbImage.write_file(path)
  end

  defp write_texture(path, :none) do
    {r, g, b} = @default_colour
    write_texture(path, {:colour, {r, g, b, 1.0}})
  end

  # glTF states colour in linear space; a one-pixel PNG is read as sRGB.
  defp channel(value), do: round(:math.pow(max(value, 0.0), 1 / 2.2) * 255)

  # sobelow_skip ["Traversal.FileModule"]
  # `into` is the corpus directory the command line names; the file name is
  # fixed.
  defp attribution(into, entries) do
    rows =
      Enum.map(entries, fn entry ->
        """
        ## #{entry["name"]} (`#{entry["id"]}`)

        - Source: Objaverse 1.0, uid `#{entry["uid"]}`
        - Author: #{entry["author"]}
        - Page: #{entry["page"]}
        - Licence: #{entry["licence"]} (as the model page states it)
        """
      end)

    File.write(Path.join(into, "ATTRIBUTION.md"), [
      "# Attribution\n\n",
      "Every object below is a third-party 3D model, used under the licence its own page states.\n",
      "The licence of each model is repeated beside it in `metadata.json`.\n\n",
      rows
    ])
  end
end
