defmodule Monty.Studio.JobsTest do
  @moduledoc """
  The queue, as the page reads it: a job, its state, and the run it is for.

  The queue runs jobs by hand in tests (`testing: :manual`), so nothing here
  races a worker: what is under test is what a job row says, not how Oban
  schedules it.
  """

  use ExTbpMontyWeb.ConnCase, async: true

  alias Monty.Studio.{Jobs, RunHistory, RunLog}

  defp record_run do
    {:ok, opened} = Monty.Studio.open("tutorial/first_experiment")
    {:ok, record} = RunHistory.start(RunLog.attributes(opened, 3))
    record
  end

  describe "a queued run" do
    test "is listed with its Oban state and the status of its record" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)

      assert [listed] = Jobs.list()
      assert listed.id == job.id
      assert listed.state == "available"
      assert listed.queue == "studio"
      assert listed.worker == "Monty.Studio.Jobs.Run"
      assert listed.run_id == record.id
      assert listed.run_status == "running"
      assert listed.error == nil
    end

    test "keeps its job visible after the run it worked on is gone" do
      record = record_run()
      {:ok, _job} = Jobs.Run.enqueue_run(record)
      {:ok, _deleted} = RunHistory.delete(record)

      assert [listed] = Jobs.list()
      assert listed.run_id == record.id
      assert listed.run_status == nil
    end
  end

  test "the counts say what the queue holds" do
    assert Jobs.counts() == %{}

    record = record_run()
    {:ok, _job} = Jobs.Run.enqueue_run(record)

    assert Jobs.counts() == %{"available" => 1}
  end

  test "a job's last error is the one that stopped it" do
    record = record_run()
    {:ok, job} = Jobs.Run.enqueue_run(record)

    job
    |> Ecto.Changeset.change(
      errors: [%{"error" => "first"}, %{"error" => "the one that stopped it"}]
    )
    |> ExTbpMonty.Repo.update!()

    assert [listed] = Jobs.list()
    assert listed.error == "the one that stopped it"
  end
end
