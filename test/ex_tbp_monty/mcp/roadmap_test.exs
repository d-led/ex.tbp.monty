defmodule ExTbpMonty.Mcp.RoadmapTest do
  # The roadmap data is application configuration, so these read one stub at a time.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Roadmap
  alias ExTbpMonty.Mcp.Test.FakeDocsHttp

  @data "https://futureworkwidget.thousandbrains.ai/data.json"

  @tasks """
  [
    {
      "path": "docs/future-work/voting-improvements/vote-on-state.md",
      "path1": "future-work",
      "path2": "voting-improvements",
      "title": "Vote on state",
      "description": "Columns could carry the state of what they see.",
      "slug": "vote-on-state",
      "text": "Columns could carry something about the state of what they see, and vote with it.",
      "estimated-scope": "medium",
      "improved-metric": ["accuracy"],
      "output-type": ["RFC"],
      "status": "open",
      "skills": ["python", "monty-advanced"],
      "rfc": "https://github.com/thousandbrainsproject/tbp.monty/blob/main/rfcs/0001.md",
      "contributor": ["vkakerbeck"],
      "hidden": null
    },
    {
      "path": "docs/future-work/voting-improvements/clean-up-voting.md",
      "path1": "future-work",
      "path2": "voting-improvements",
      "title": "Clean up voting",
      "description": null,
      "slug": "clean-up-voting",
      "text": "Tidy the voting module.\\n\\nThe old helpers can go.",
      "estimated-scope": "small",
      "improved-metric": ["community-engagement"],
      "output-type": ["documentation"],
      "status": "completed",
      "skills": ["python"],
      "rfc": null,
      "contributor": ["tristanls-tbp", "ramyamounir"],
      "hidden": null
    }
  ]
  """

  setup do
    FakeDocsHttp.serve(%{@data => @tasks})
  end

  describe "the tasks" do
    test "are the records the project's roadmap page shows, with the metadata it records" do
      assert {:ok, [%{id: "clean-up-voting"}, %{id: "vote-on-state"} = task]} = Roadmap.tasks()

      assert task.title == "Vote on state"
      assert task.section == "voting-improvements"
      assert task.status == "open"
      assert task.scope == "medium"
      assert task.output == "RFC"
      assert task.metric == "accuracy"
      assert task.skills == "python, monty-advanced"
      assert task.contributor == "vkakerbeck"
      assert task.online == "https://docs.thousandbrains.org/docs/vote-on-state"
    end

    test "carry the page's own opening line when the record has no description" do
      assert {:ok, tasks} = Roadmap.tasks(status: "completed")
      assert [%{description: "Tidy the voting module."}] = tasks
    end

    test "are filtered by status" do
      assert {:ok, [%{id: "vote-on-state"}]} = Roadmap.tasks(status: "open")
      assert {:ok, [%{id: "clean-up-voting"}]} = Roadmap.tasks(status: "completed")
    end

    test "are filtered by a skill the task asks for" do
      assert {:ok, [%{id: "vote-on-state"}]} = Roadmap.tasks(skill: "monty-advanced")
    end

    test "are filtered by words the task contains" do
      assert {:ok, [%{id: "vote-on-state"}]} = Roadmap.tasks(query: "state columns")
      assert {:ok, []} = Roadmap.tasks(query: "state quaternion")
    end

    test "say the roadmap could not be read when the data is not a list of tasks" do
      FakeDocsHttp.serve(%{@data => ~s({"tasks": []})})

      assert {:error, message} = Roadmap.tasks()
      assert message =~ "could not be read"
    end

    test "say the roadmap could not be read, rather than raising, when the data does not answer" do
      FakeDocsHttp.serve(%{@data => {:error, :econnrefused}})

      assert {:error, message} = Roadmap.tasks()
      assert message =~ "could not be read"
      assert message =~ "Try again"
    end
  end

  describe "one task" do
    test "is the whole record, body included" do
      assert {:ok, task} = Roadmap.task("vote-on-state")
      assert task.body =~ "carry something about the state"
    end

    test "can be named by the path the project records" do
      assert {:ok, %{id: "vote-on-state"}} =
               Roadmap.task("future-work/voting-improvements/vote-on-state.md")

      assert {:ok, %{id: "vote-on-state"}} =
               Roadmap.task("docs/future-work/voting-improvements/vote-on-state.md")
    end

    test "is an error when there is no such task" do
      assert {:error, message} = Roadmap.task("no-such-task")
      assert message =~ "monty_roadmap"
    end
  end

  test "the sections name themselves and count their tasks" do
    assert [%{name: "voting-improvements", tasks: 2}] = Roadmap.sections()
  end

  test "the sections are empty, not an error, when the roadmap cannot be read" do
    FakeDocsHttp.serve(%{@data => {500, "nope"}})

    assert Roadmap.sections() == []
  end
end
