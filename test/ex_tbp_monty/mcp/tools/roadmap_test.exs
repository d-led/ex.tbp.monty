defmodule ExTbpMonty.Mcp.Tools.RoadmapTest do
  # The roadmap data is application configuration, so these read one stub at a time.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Test.FakeDocsHttp
  alias ExTbpMonty.Mcp.Tools.Roadmap

  @data "https://futureworkwidget.thousandbrains.ai/data.json"

  @tasks """
  [
    {
      "path": "docs/future-work/voting-improvements/vote-on-state.md",
      "path2": "voting-improvements",
      "title": "Vote on state",
      "description": "Columns could carry the state of what they see.",
      "slug": "vote-on-state",
      "text": "Columns could carry something about the state of what they see.",
      "estimated-scope": "medium",
      "improved-metric": ["accuracy"],
      "output-type": ["RFC"],
      "status": "open",
      "skills": ["python", "monty-advanced"]
    },
    {
      "path": "docs/future-work/voting-improvements/clean-up-voting.md",
      "path2": "voting-improvements",
      "title": "Clean up voting",
      "description": "Tidy the voting module.",
      "slug": "clean-up-voting",
      "text": "Tidy the voting module.",
      "estimated-scope": "small",
      "improved-metric": ["community-engagement"],
      "output-type": ["documentation"],
      "status": "completed",
      "skills": ["python"]
    }
  ]
  """

  setup do
    FakeDocsHttp.serve(%{@data => @tasks})
  end

  describe "monty_roadmap" do
    test "lists the tasks, and counts them all even when it shows fewer" do
      assert {:ok, %{text: text, structured: %{count: 2, tasks: tasks}}} = Roadmap.tasks(%{}, %{})

      assert length(tasks) == 2
      assert text =~ "vote-on-state"
      assert text =~ "open, medium scope, RFC"
    end

    test "says how many more there are when the limit cuts the list" do
      assert {:ok, %{text: text, structured: %{count: 2, tasks: tasks}}} =
               Roadmap.tasks(%{"limit" => 1}, %{})

      assert length(tasks) == 1
      assert text =~ "1 more; raise `limit`"
    end

    test "names the sections when nothing matches" do
      assert {:ok, %{text: text, structured: %{count: 0, tasks: []}}} =
               Roadmap.tasks(%{"query" => "aardvark"}, %{})

      assert text =~ "No task matches"
      assert text =~ "voting-improvements"
    end

    test "says the roadmap could not be read rather than failing when the data does not answer" do
      FakeDocsHttp.serve(%{@data => {:error, :econnrefused}})

      assert {:error, message} = Roadmap.tasks(%{}, %{})
      assert message =~ "could not be read"
    end

    test "refuses a limit that is not a number" do
      assert Roadmap.tasks(%{"limit" => "many"}, %{}) == {:error, "`limit` must be an integer."}
    end
  end

  describe "monty_roadmap_task" do
    test "gives the whole task, with its body as markdown" do
      assert {:ok, %{text: text, structured: task}} =
               Roadmap.task(%{"task" => "vote-on-state"}, %{})

      assert task.id == "vote-on-state"
      assert is_binary(task.markdown)
      refute Map.has_key?(task, :body)
      assert text =~ "# Vote on state"
    end

    test "asks for the task it needs" do
      assert Roadmap.task(%{}, %{}) == {:error, "`task` is required."}
    end

    test "says so when there is no such task" do
      assert {:error, message} = Roadmap.task(%{"task" => "no-such-task"}, %{})
      assert message =~ "no-such-task"
    end
  end
end
