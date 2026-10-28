defmodule ExTbpMonty.Mcp.Roadmap do
  @moduledoc """
  Monty's future work, read as tasks.

  Each page under `docs/future-work/<section>/` is one task, and its front
  matter is the same metadata the project's future-work widget is built from:
  status, scope, output type, the skills it wants, the metric it would improve.
  Reading the file rather than a copy of the table means "what is on the
  roadmap" and "what does this task ask for" cannot answer differently.

  The pages directly under `future-work/` are section introductions, not tasks,
  and are read as such: a section names itself and counts what is in it.
  """

  alias ExTbpMonty.Mcp.{Docs, Markdown}

  @section_dir "future-work"

  @doc "The directory Monty's future work is read from."
  @spec root() :: Path.t()
  def root, do: Path.join(Docs.root(), @section_dir)

  @doc """
  Every task, filtered by any of `:section`, `:status`, `:skill` and `:query`.

  The body is left out — a list is a list — and `task/1` is what reads one page
  whole.
  """
  @spec tasks(keyword()) :: [map()]
  def tasks(opts \\ []) do
    @section_dir
    |> task_paths()
    |> Enum.flat_map(&load/1)
    |> Enum.filter(&matches?(&1, opts))
    |> Enum.sort_by(&{&1.section, &1.title})
    |> Enum.map(&Map.drop(&1, [:body]))
  end

  @doc "One task, by id (its file name) or by path under `docs/`."
  @spec task(String.t()) :: {:ok, map()} | {:error, String.t()}
  def task(id_or_path) do
    wanted = String.trim_trailing(id_or_path, ".md")

    @section_dir
    |> task_paths()
    |> Enum.flat_map(&load/1)
    |> Enum.find(fn task ->
      wanted in [task.id, task.path, String.trim_trailing(task.path, ".md")]
    end)
    |> case do
      nil -> {:error, "No roadmap task `#{id_or_path}`. Try monty_roadmap to list them."}
      task -> {:ok, task}
    end
  end

  @doc "The sections of the roadmap, and how many tasks each holds."
  @spec sections() :: [%{name: String.t(), title: String.t(), tasks: non_neg_integer()}]
  def sections do
    counts =
      @section_dir |> task_paths() |> Enum.flat_map(&load/1) |> Enum.frequencies_by(& &1.section)

    root()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      name = Path.basename(path, ".md")
      {meta, body} = path |> File.read!() |> Markdown.frontmatter()

      %{
        name: name,
        title: meta["title"] || Markdown.first_heading(body) || name,
        tasks: Map.get(counts, name, 0)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp task_paths(section_dir) do
    Path.wildcard(Path.join([Docs.root(), section_dir, "*", "*.md"]))
    |> Enum.sort()
  end

  defp load(path) do
    case File.read(path) do
      {:ok, text} -> [parse(path, text)]
      {:error, _reason} -> []
    end
  end

  defp parse(path, text) do
    {meta, body} = Markdown.frontmatter(text)
    relative = Path.relative_to(path, Docs.root())
    id = Path.basename(path, ".md")

    %{
      id: id,
      section: path |> Path.dirname() |> Path.basename(),
      title: meta["title"] || Markdown.first_heading(body) || id,
      description: meta["description"] || "",
      status: meta["status"] || "open",
      scope: meta["estimated-scope"] || "",
      output: meta["output-type"] || "",
      skills: meta["skills"] || "",
      metric: meta["improved-metric"] || "",
      rfc: meta["rfc"] || "",
      path: relative,
      online: Docs.base_url() <> id,
      body: body
    }
  end

  defp matches?(task, opts) do
    matches_section?(task, opts[:section]) and
      matches_status?(task, opts[:status]) and
      matches_skill?(task, opts[:skill]) and
      matches_query?(task, opts[:query])
  end

  defp matches_section?(_task, nil), do: true
  defp matches_section?(task, section), do: task.section == section

  defp matches_status?(_task, nil), do: true
  defp matches_status?(task, status), do: task.status == status

  defp matches_skill?(_task, nil), do: true

  defp matches_skill?(task, skill) do
    skills = task.skills |> String.downcase() |> String.split([",", " "], trim: true)
    String.downcase(skill) in skills
  end

  # Every word of the query, because a task asked about by two words is a task
  # that should be about both of them.
  defp matches_query?(_task, nil), do: true

  defp matches_query?(task, query) do
    haystack = String.downcase(task.title <> " " <> task.description <> " " <> task.body)

    query
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]-]+/u, trim: true)
    |> Enum.all?(&String.contains?(haystack, &1))
  end
end
