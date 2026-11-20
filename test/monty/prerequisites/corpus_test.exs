defmodule Monty.Prerequisites.CorpusTest do
  use ExUnit.Case, async: true

  # The sets tree this application ships: one directory per corpus, a JSON
  # manifest of the objects it carries, and the configs that step them.
  #
  # A corpus that dropped an object and a config that still names it used to
  # disagree until a run failed forty minutes in with "unknown object type:
  # boykin_spaniel is not a directory" — a fact about two files that no test
  # looked at together. The manifest records the ones it excludes and why; a
  # config naming one of those is the same defect, said in a sentence instead.
  @sets Path.join(:code.priv_dir(:ex_tbp_monty), "monty_experiments/sets")

  test "every object a config names is one its corpus carries" do
    for {manifest, set} <- manifests(), {file, object} <- named_objects(set) do
      assert object in ids(manifest, "objects"),
             "#{relative(file)} steps #{object}, " <>
               "which #{Path.basename(manifest)} does not carry#{why_not(manifest, object)}"
    end
  end

  defp relative(file), do: Path.join("sets", Path.relative_to(file, @sets))

  # A set with a manifest and no config that names an object is not a corpus, and
  # a set that names objects with no manifest is one this test cannot speak for —
  # both are answers here rather than errors.
  defp manifests do
    for file <- Path.wildcard(Path.join(@sets, "*/*.json")),
        do: {file, Path.dirname(file)}
  end

  defp ids(manifest, key) do
    manifest
    |> File.read!()
    |> JSON.decode!()
    |> Map.get(key, [])
    |> Enum.map(& &1["id"])
  end

  defp why_not(manifest, object) do
    reason =
      manifest
      |> File.read!()
      |> JSON.decode!()
      |> Map.get("excluded", [])
      |> Enum.find_value(fn excluded ->
        if excluded["id"] == object, do: excluded["reason"]
      end)

    if reason, do: " — it is excluded: #{reason}", else: ""
  end

  # The object lists a set's own configs name, in either half of the tree: an
  # interface says which objects an episode steps, and an environment may say it
  # again for the scene it builds.
  defp named_objects(set) do
    for pattern <- ["env_interface/*.yaml", "environment/*.yaml"],
        file <- Path.wildcard(Path.join([set, "conf", pattern])),
        object <- objects_in(YamlElixir.read_from_file!(file)),
        do: {file, object}
  end

  defp objects_in(document) when is_map(document) do
    own =
      case document do
        %{"object_names" => names} when is_list(names) -> names
        _no_objects -> []
      end

    own ++ Enum.flat_map(Map.values(document), &objects_in/1)
  end

  defp objects_in(document) when is_list(document), do: Enum.flat_map(document, &objects_in/1)
  defp objects_in(_leaf), do: []
end
