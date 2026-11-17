defmodule ExTbpMonty.Cad.Objects do
  @moduledoc """
  A part's features, written as the object set the MuJoCo world steps.

  The world reads one directory per object: `textured.obj`, `texture_map.png` and
  `metadata.json` (`refpos`, `refquat`, `scale`). `MontyCad.Export` answers the
  geometry — one mesh per feature record and one for the body, in metres — and
  this writes it in that shape, so a run on meshes steps the same surfaces the
  run in the CAD world ray cast.

  ## No rescaling, on purpose

  A feature is as big as the part says: `scale` is one. The memory a training run
  wrote was made against this geometry, and what a graph stores includes
  curvatures — a scale moves them by `log s`, so an object set normalised to a
  convenient height would be a different shape from the one learned. What the
  metadata places is *where* the object sits: centred on its own footprint and
  resting on `z = 0`.

  ## The exporter is asked for, not linked

  `ex_monty_cad` is another package, and this application does not depend on it:
  the studio deliberately carries no geometry. So the module that answers the
  meshes is named at the call (`:exporter`), and a node without it is refused with
  a sentence instead of failing to compile.
  """

  alias ExTbpMonty.Objaverse.Import

  # The one module that knows a B-rep. Named rather than aliased, because a
  # compile-time reference would be a dependency this application does not have.
  @default_exporter Module.concat(["MontyCad", "Export"])

  @type row :: %{
          name: String.t(),
          object: String.t(),
          faces: non_neg_integer(),
          vertices: non_neg_integer()
        }

  @doc """
  Writes `part` as an object set in `into`, one directory per feature and one for
  the body, and answers what was written.

  Options: `:exporter` — the module that answers the meshes (default
  `MontyCad.Export`), which is how a test drives this without the geometry.
  """
  @spec write(Path.t(), Path.t(), keyword()) :: {:ok, [row()]} | {:error, String.t()}
  def write(part, into, options \\ []) do
    exporter = Keyword.get(options, :exporter, @default_exporter)

    if Code.ensure_loaded?(exporter) do
      case exporter.feature_meshes(part) do
        {:ok, meshes} -> {:ok, write_all(meshes, into)}
        {:error, reason} -> {:error, "#{part} could not be meshed: #{inspect(reason)}"}
      end
    else
      {:error,
       "#{inspect(exporter)} is not on this node: add `ex_monty_cad` to write a " <>
         "part as an object set."}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `into` is the directory an operator names and the object name is the
  # recognition's own record id, so neither comes from a request.
  defp write_all(meshes, into) do
    File.mkdir_p!(into)
    Enum.map(meshes, &write_mesh(&1, into))
  end

  @doc """
  Writes one mesh as one object, and answers the row it wrote.

  This is what an evaluation needs: a memory of a *part* is compared against a
  mesh of that part, so the caller decides what the one object is called.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # As above: the directory is the caller's, and the name is the recognition's.
  @spec write_mesh(map(), Path.t()) :: row()
  def write_mesh(mesh, into) do
    object = object_name(mesh.name)
    directory = Path.join(into, object)
    File.mkdir_p!(directory)

    Import.write_object(Path.join(directory, "textured.obj"), %{
      vertices: Enum.map(mesh.vertices, &List.to_tuple/1),
      triangles: Enum.map(mesh.triangles, &List.to_tuple/1),
      uvs: nil
    })

    {red, green, blue} = mesh.colour

    Import.write_texture(Path.join(directory, "texture_map.png"), {
      :colour,
      {red, green, blue, 1.0}
    })

    File.write!(Path.join(directory, "metadata.json"), JSON.encode!(placement(mesh.vertices)))

    %{
      name: mesh.name,
      object: object,
      faces: length(mesh.triangles),
      vertices: length(mesh.vertices)
    }
  end

  # A record id is a name, not a path: `bosses/0` is one directory called
  # `bosses_0`, and the row says which name it was written for.
  defp object_name(name), do: String.replace(name, "/", "_")

  # Where the object sits in the world's frame. `refquat` is the identity because
  # a mesh from a part arrives in the part's own frame, which is the world's: both
  # are z-up and both are metres by the time they get here.
  defp placement(vertices) do
    {min_x, max_x, min_y, max_y, min_z, _max_z} = bounds(vertices)

    %{
      "refpos" => [
        rounded((min_x + max_x) / 2),
        rounded((min_y + max_y) / 2),
        rounded(min_z)
      ],
      "refquat" => [1.0, 0.0, 0.0, 0.0],
      "scale" => [1.0, 1.0, 1.0]
    }
  end

  defp bounds([[x, y, z] | rest]) do
    Enum.reduce(rest, {x, x, y, y, z, z}, fn [vx, vy, vz], {x0, x1, y0, y1, z0, z1} ->
      {min(x0, vx), max(x1, vx), min(y0, vy), max(y1, vy), min(z0, vz), max(z1, vz)}
    end)
  end

  defp rounded(value), do: Float.round(value, 6)
end
