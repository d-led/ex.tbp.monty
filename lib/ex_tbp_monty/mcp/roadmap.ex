defmodule ExTbpMonty.Mcp.Roadmap do
  @moduledoc """
  Monty's roadmap: what the project says it intends to do, one task per record.

  The data is the file the project's own roadmap page renders. That page
  (`docs.thousandbrains.org/docs/project-roadmap`) embeds the future-work widget,
  and the widget loads `data.json` from its own host — one record per task, with
  the status, scope, output type, skills and metric the project records for it.
  Reading the same file the widget reads means a task added, finished or
  re-scoped on the roadmap page changes the answer here, with nothing in this
  application to edit; it also means no checkout has to exist beside this one at
  run time, which is the only reason the roadmap used to be unanswerable in an
  image.

  The widget also has a "hide completed" toggle, and that is a reader's filter,
  not project data: the tasks come back whatever their status, and a caller asks
  for the ones it wants.
  """

  require Logger

  alias ExTbpMonty.Mcp.Docs

  @default_url "https://futureworkwidget.thousandbrains.ai/data.json"

  @type task :: %{
          id: String.t(),
          section: String.t() | nil,
          title: String.t(),
          description: String.t(),
          status: String.t(),
          scope: String.t(),
          output: String.t(),
          skills: String.t(),
          metric: String.t(),
          rfc: String.t(),
          contributor: String.t(),
          path: String.t() | nil,
          online: String.t(),
          body: String.t()
        }

  @doc """
  Where the roadmap data is read from.

  `:monty_roadmap_url` replaces it, which is how a test pins the data instead of
  asking the project's server.
  """
  @spec url() :: String.t()
  def url, do: Application.get_env(:ex_tbp_monty, :monty_roadmap_url, @default_url)

  @doc """
  Every task, filtered by any of `:section`, `:status`, `:skill` and `:query`.

  The body is left in place: `tools/roadmap.ex` drops it from a list, and
  `task/1` is the call that shows one task whole.

  `{:error, message}` when the roadmap cannot be read — the tool says it in
  those words rather than failing; a server that cannot reach a data file still
  owes a caller an answer.
  """
  @spec tasks(keyword()) :: {:ok, [task()]} | {:error, String.t()}
  def tasks(opts \\ []) do
    with {:ok, all} <- all() do
      {:ok,
       all
       |> Enum.filter(&matches?(&1, opts))
       |> Enum.sort_by(&{&1.section, &1.title})}
    end
  end

  @doc "One task, by slug, by repo path, or by `future-work/<section>/<slug>.md`."
  @spec task(String.t()) :: {:ok, task()} | {:error, String.t()}
  def task(id_or_path) do
    wanted = normalise(id_or_path)

    with {:ok, all} <- all() do
      case Enum.find(all, &(wanted in Enum.map(names(&1), fn name -> normalise(name) end))) do
        nil ->
          {:error, "No roadmap task `#{id_or_path}`. Try monty_roadmap to list them."}

        task ->
          {:ok, task}
      end
    end
  end

  @doc """
  The sections of the roadmap and how many tasks each holds.

  `[]` when the roadmap cannot be read: this only ever decorates an answer (it
  names the sections when a filter matches nothing), so a failure here must not
  turn a useful message into a second failure.
  """
  @spec sections() :: [%{name: String.t(), tasks: non_neg_integer()}]
  def sections do
    case all() do
      {:ok, all} ->
        all
        |> Enum.frequencies_by(& &1.section)
        |> Enum.map(fn {name, count} -> %{name: name, tasks: count} end)
        |> Enum.sort_by(& &1.name)

      {:error, _reason} ->
        []
    end
  end

  # -- reading ---------------------------------------------------------------

  defp all do
    case http().get(url()) do
      {:ok, %{status: 200, body: body}} -> decode(body)
      {:ok, %{status: status}} -> failed({:http_status, status})
      {:error, reason} -> failed(reason)
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries |> Enum.filter(&task?/1) |> Enum.map(&parse/1)}

      _not_a_task_list ->
        failed(:unexpected_body)
    end
  end

  # A record with no slug is not a task anyone can name, so it is not one.
  defp task?(entry) when is_map(entry), do: is_binary(entry["slug"]) and entry["slug"] != ""
  defp task?(_not_a_record), do: false

  defp failed(reason) do
    Logger.warning("the roadmap data could not be read: #{inspect(reason)}")

    {:error,
     "Monty's roadmap could not be read just now (the project's roadmap data did not answer). " <>
       "Try again in a moment."}
  end

  defp parse(entry) do
    text = entry["text"] || ""

    %{
      id: entry["slug"],
      section: entry["path2"],
      title: entry["title"] || entry["slug"],
      description: description(entry, text),
      status: entry["status"] || "open",
      scope: entry["estimated-scope"] || "",
      output: joined(entry["output-type"]),
      skills: joined(entry["skills"]),
      metric: joined(entry["improved-metric"]),
      rfc: entry["rfc"] || "",
      contributor: joined(entry["contributor"]),
      path: entry["path"],
      online: Docs.online(entry["slug"]),
      body: text
    }
  end

  # The data carries a one-line description for some tasks and none for others;
  # when it is absent the page's own opening paragraph says the same thing.
  defp description(%{"description" => description}, _text)
       when is_binary(description) and description != "",
       do: description

  defp description(_entry, text) do
    text
    |> String.split("\n")
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.trim()
  end

  defp joined(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  defp joined(value) when is_binary(value), do: value
  defp joined(_none), do: ""

  defp names(task), do: [task.id, task.path]

  defp normalise(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("docs/")
    |> String.trim_trailing(".md")
  end

  defp http, do: Application.get_env(:ex_tbp_monty, :docs_http, ExTbpMonty.Mcp.Docs.Http.Req)

  # -- filtering -------------------------------------------------------------

  defp matches?(task, opts) do
    matches_section?(task, opts[:section]) and
      matches_status?(task, opts[:status]) and
      matches_skill?(task, opts[:skill]) and
      matches_query?(task, opts[:query])
  end

  defp matches_section?(_task, nil), do: true
  defp matches_section?(task, section), do: task.section == section

  defp matches_status?(_task, nil), do: true
  defp matches_status?(task, status), do: String.downcase(task.status) == String.downcase(status)

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
