defmodule ExTbpMonty.Mcp.Tools.Roadmap do
  @moduledoc """
  Monty's roadmap: what the project intends to do, one task per page.

  A task's front matter is what the project's own future-work table is built
  from, so a status here is the project's status, not this server's opinion. The
  tools filter by section, status, skill and words; the full task page is a
  second call, because a list of forty tasks with their bodies in it is a list
  nobody reads.
  """

  alias ExTbpMonty.Mcp.{Args, Roadmap}

  @doc "`monty_roadmap`: the tasks, filtered."
  def tasks(args, _ctx) do
    with {:ok, section} <- Args.optional(args, "section"),
         {:ok, status} <- Args.optional(args, "status"),
         {:ok, skill} <- Args.optional(args, "skill"),
         {:ok, query} <- Args.optional(args, "query"),
         {:ok, limit} <- Args.integer(args, "limit", default: 25, min: 1, max: 200) do
      found = Roadmap.tasks(section: section, status: status, skill: skill, query: query)

      {:ok,
       %{
         text: list_text(found, limit),
         structured: %{count: length(found), tasks: Enum.take(found, limit)}
       }}
    end
  end

  @doc "`monty_roadmap_task`: one task, whole."
  def task(args, _ctx) do
    with {:ok, id} <- Args.required(args, "task"),
         {:ok, task} <- Roadmap.task(id) do
      {:ok,
       %{
         text: task_text(task),
         structured: Map.delete(task, :body) |> Map.put(:markdown, task.body)
       }}
    end
  end

  defp list_text(tasks, limit) do
    if tasks == [] do
      "No task matches. Sections: #{Enum.map_join(Roadmap.sections(), ", ", & &1.name)}."
    else
      Enum.map_join(Enum.take(tasks, limit), "\n", fn task ->
        "- **#{task.title}** (`#{task.id}`, #{task.section}) — #{task.status}, " <>
          "#{task.scope} scope, #{task.output}; skills: #{task.skills}\n" <>
          "  #{task.description}"
      end) <>
        if(length(tasks) > limit,
          do: "\n\n#{length(tasks) - limit} more; raise `limit`.",
          else: ""
        )
    end
  end

  defp task_text(task) do
    "# #{task.title}\n" <>
      "#{task.online}\n" <>
      "`#{task.path}`\n" <>
      "status: #{task.status} · scope: #{task.scope} · output: #{task.output} · " <>
      "skills: #{task.skills} · metric: #{task.metric}\n\n" <>
      task.body
  end
end
