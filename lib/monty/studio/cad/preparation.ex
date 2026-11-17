defmodule Monty.Studio.Cad.Preparation do
  @moduledoc """
  A CAD part's two inputs, written from the part file the experiment names.

  Both are Monty's own formats, because both are read by Monty's own code: the
  memory is the library format (`<libraries>/<release>/<name>.jsonl.gz`) and the
  object set is the MuJoCo object directory
  (`<data_path>/<object>/{textured.obj,texture_map.png,metadata.json}`). Nothing
  here invents a format — the part file is the one input, and the same part
  answers both, which is what makes a memory and a mesh comparable at all.

  The geometry belongs to another package (`ex_monty_cad`), named at the call
  rather than aliased: a node without it says so instead of failing to compile,
  and a test drives the writer it is given.

  This is what `/prerequisites` runs as a build (`Monty.Prerequisites.Build`):
  the plan comes from the experiment — its `object_names`, its
  `model_name_or_path` and its environment's `data_path` — so a new part is a
  new config and no code.
  """

  alias Monty.Studio.{Memory, Setup}

  @trainer Module.concat(["MontyCad", "Training"])
  @exporter Module.concat(["MontyCad", "Export"])

  @typedoc """
  What preparing a part would write, and from what.

    * `part` — the object name the experiment steps (`object_names: [plate]`)
    * `step` — the file the geometry comes from
    * `name` and `release` — the memory's address, as the config names it
    * `memory` — the library file, whether or not it is there
    * `objects` — the directory the object set is written into
  """
  @type plan :: %{
          part: String.t(),
          step: Path.t(),
          name: String.t(),
          release: String.t(),
          memory: Path.t(),
          objects: Path.t()
        }

  @doc """
  What `setup` needs writing, or the sentence that says why it cannot be.

  Reads only the experiment: its `object_names` say which object a run steps,
  `model_name_or_path` says which memory it loads, and the environment's
  `data_path` says where its objects live. A run of another world has nothing to
  plan, and says so.
  """
  @spec plan(Setup.t()) :: {:ok, plan()} | {:error, String.t()}
  def plan(%Setup{} = setup) do
    with {:ok, part} <- object_of(setup),
         {:ok, step} <- step_of(part),
         {:ok, name, release} <- memory_of(setup),
         {:ok, objects} <- objects_of(setup) do
      {:ok,
       %{
         part: part,
         step: step,
         name: name,
         release: release,
         memory: Memory.path_for(name, release),
         objects: objects
       }}
    end
  end

  @doc """
  Writes the memory and the object set a plan describes.

  Answers what was written, so a page can say it rather than guess: the memory's
  path, the directory the objects went into, and how many objects there are.
  """
  @spec prepare(plan(), keyword()) ::
          {:ok, %{memory: Path.t(), objects: Path.t(), written: non_neg_integer()}}
          | {:error, String.t()}
  def prepare(%{} = plan, options \\ []) do
    with {:ok, nodes} <- write_memory(plan, Keyword.get(options, :trainer, @trainer)),
         {:ok, written} <- write_objects(plan, Keyword.get(options, :exporter, @exporter)) do
      {:ok, %{memory: plan.memory, objects: plan.objects, written: written, nodes: nodes}}
    end
  end

  # The memory is the part as one object, which is what a config naming
  # `<release>/<part>_part` loads: one graph for the whole part, not one per face.
  defp write_memory(plan, trainer) do
    if Code.ensure_loaded?(trainer) do
      case trainer.write_library([{plan.part, plan.step}], plan.memory, labels: :part) do
        {:ok, %{nodes: nodes}} ->
          {:ok, nodes}

        {:error, reason} ->
          {:error, "#{plan.step} could not be taught: #{inspect(reason)}"}
      end
    else
      {:error,
       "#{inspect(trainer)} is not on this node: add `ex_monty_cad` to write a part's memory."}
    end
  end

  # The object set is the same part as triangles, written where the config's
  # `data_path` looks — one directory named for the object the memory holds.
  defp write_objects(plan, exporter) do
    if Code.ensure_loaded?(exporter) do
      with {:ok, mesh} <- exporter.part_mesh(plan.step, name: plan.part) do
        _written = ExTbpMonty.Cad.Objects.write_mesh(mesh, plan.objects)
        {:ok, 1}
      end
    else
      {:error,
       "#{inspect(exporter)} is not on this node: add `ex_monty_cad` to write a part's meshes."}
    end
  end

  defp object_of(setup) do
    case Setup.objects(setup) do
      [part | _rest] when is_binary(part) and part != "" -> {:ok, part}
      _none -> {:error, "this experiment names no object to prepare"}
    end
  end

  # The part file is named for the object, the way Monty's object sets are named
  # for the objects they hold; the parts directory is where the file lives.
  defp step_of(part) do
    case Enum.find(Setup.cad_parts(), &(Path.rootname(&1) == part)) do
      nil ->
        {:error,
         "there is no part #{inspect(part)}: #{Enum.join(Setup.parts_dirs(), " and ")} hold " <>
           inspect(Setup.cad_parts())}

      file ->
        {:ok, path_of(file)}
    end
  end

  defp path_of(file) do
    Enum.find_value(Setup.parts_dirs(), fn dir -> regular(Path.join(dir, file)) end) ||
      Path.expand(file)
  end

  defp regular(path), do: if(File.regular?(path), do: path)

  defp memory_of(setup) do
    case setup.model_name_or_path do
      path when is_binary(path) and path != "" ->
        {:ok, Path.basename(path), path |> Path.dirname() |> Path.basename()}

      _none ->
        {:error, "this experiment names no memory to write: `model_name_or_path` is empty"}
    end
  end

  defp objects_of(%Setup{environment: %{data_path: path}}) when is_binary(path), do: {:ok, path}
  defp objects_of(_setup), do: {:error, "this experiment's environment has no data path"}
end
