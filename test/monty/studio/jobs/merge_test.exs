defmodule Monty.Studio.Jobs.MergeTest do
  @moduledoc """
  The step between a training wave and the evaluation that reads it.

  Monty's `post_parallel_train` is the reference: when the pool is empty, load
  every part's model, merge them, save the merged one, and only then run the
  evaluation. These cases say what that means as a job — that it waits rather
  than merges half a memory, that it merges what the parts built, and that the
  evaluation it starts reads it.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Studio.Jobs.Merge
  alias Monty.Studio.{Learned, Memories, Memory, RunHistory, RunLog}
  alias Monty.Test.Tmp

  # An experiment that trains on two objects, so a batch of it has two training
  # parts that each learn something.
  @training "tutorial/surf_agent_2obj_unsupervised"

  setup do
    _root = Tmp.env_dir("studio-merge", :studio_artifacts_dir)
    {:ok, libraries: Tmp.env_dir("studio-merge-libraries", :monty_libraries_dir)}
  end

  describe "a batch whose training is still going" do
    test "is asked about again, not merged half-finished" do
      {:ok, opened} = Monty.Studio.open(@training)
      batch = Ecto.UUID.generate()

      _part = train_part(opened, batch, 0, 2, [0])

      assert {:snooze, 1} = perform(batch, opened.name, eval: [])
    end
  end

  describe "a batch whose training finished" do
    test "merges what the parts learned, and queues the evaluation that reads it", %{
      libraries: libraries
    } do
      {:ok, opened} = Monty.Studio.open(@training)
      [%{id: module} | _rest] = opened.setup.learning_modules
      batch = Ecto.UUID.generate()

      # Two parts, one object each, as the training wave would leave them.
      for {index, object} <- [{0, "mug"}, {1, "bowl"}] do
        part = train_part(opened, batch, index, 2, [index])
        keep(part, opened, %{module => remembered(object)})
        finish(part)
      end

      assert :ok =
               perform(batch, opened.name, eval: [%{"index" => 0, "of" => 1, "episodes" => [0]}])

      # The merged memory is where a later configuration looks for it, and it is
      # both parts' work: neither object was lost in the merge.
      name = Learned.name_for(opened)
      assert {:ok, memory} = Memory.load_module(name, Learned.release(), 0, libraries)

      assert memory |> GraphMemory.get_memory_ids() |> Enum.sort() == ["bowl", "mug"]

      # And the evaluation wave reads that memory, not the library its config
      # names: a partitioned run evaluates what it just trained.
      assert [evaluation] =
               batch |> RunHistory.parts() |> Enum.reject(& &1.inputs["part"]["phases"]["train"])

      assert evaluation.status == "running"
      assert evaluation.inputs["part"]["memory"]["dir"] == Memories.batch_dir(batch)
      assert evaluation.inputs["part"]["phases"]["eval"] == [0]
    end

    test "a part that ended any other way than finished stops the batch" do
      {:ok, opened} = Monty.Studio.open(@training)
      batch = Ecto.UUID.generate()

      part = train_part(opened, batch, 0, 1, [0])
      {:ok, _failed} = RunHistory.finish(part, %{"reason" => "it died"}, "failed")

      assert {:cancel, reason} = perform(batch, opened.name, eval: [])
      assert reason =~ "ended failed"
    end

    test "a batch with no training part has nothing to merge" do
      {:ok, opened} = Monty.Studio.open(@training)

      assert :ok = perform(Ecto.UUID.generate(), opened.name, eval: [])
    end
  end

  # A training part, as the page queues it (`Monty.Studio.Partition`).
  defp train_part(opened, batch, index, of, episodes) do
    {:ok, record} =
      RunHistory.start(
        RunLog.attributes(opened, 5, hd(episodes), of, length(episodes), %{
          batch: batch,
          index: index,
          of: of,
          phases: %{train: episodes}
        })
      )

    record
  end

  # What a training part leaves in its own directory, and nowhere else: the
  # library is the merge's to write.
  defp keep(part, opened, memories) do
    Learned.keep(part.id, opened, [{:train, 1}], memories, library: false)
  end

  defp finish(part), do: RunHistory.finish(part, %{"steps" => 1}, "finished")

  defp perform(batch, experiment, eval: eval) do
    Merge.perform(%Oban.Job{
      args: %{
        "batch" => batch,
        "experiment" => experiment,
        "steps" => 2,
        "parallel" => 2,
        "eval" => eval
      }
    })
  end

  defp remembered(object_id) do
    {:ok, model} =
      GraphObjectModel.build_model(
        GraphObjectModel.new(object_id),
        [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0]],
        %{}
      )

    GraphMemory.add_graph_to_memory(GraphMemory.new(), %{"rgba" => model}, object_id)
  end
end
