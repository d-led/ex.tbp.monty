defmodule Monty.Studio.JobsTest do
  @moduledoc """
  The queue, as the page reads it: a job, its state, and the run it is for.

  The queue runs jobs by hand in tests (`testing: :manual`), so nothing here
  races a worker: what is under test is what a job row says, not how Oban
  schedules it.
  """

  use ExTbpMontyWeb.ConnCase, async: true

  import Ecto.Query

  alias ExTbpMonty.Repo
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

  describe "cancelling a job" do
    test "stops a run nobody is working on, and says so in its record" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)

      assert {:ok, :settled} = Jobs.cancel(job.id)

      assert Repo.get!(Oban.Job, job.id).state == "cancelled"

      settled = RunHistory.get(record.id)
      assert settled.status == "failed"
      assert settled.summary["reason"] == "it was stopped before it finished"
    end

    test "asks a running worker to stop instead, so it can report what it did" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)
      :ok = executing(job)

      # The worker registers itself under its run; the message is all it needs.
      {:ok, _owner} =
        Registry.register(Monty.Runtime.Registry, {:studio_run, record.id}, "model-1")

      assert {:ok, :stopping} = Jobs.cancel(job.id)
      assert_received :stop

      # The job is not cancelled: Oban cancels by ending the process, and the
      # process is the only thing that can say what the run did.
      assert Repo.get!(Oban.Job, job.id).state == "executing"

      # The worker has not ended yet, so the record is still its to close.
      assert RunHistory.get(record.id).status == "running"
    end

    test "tells anyone watching the run that it ended" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))

      _ = Jobs.cancel(job.id)

      assert_received {:studio, _run_id,
                       {:failed, %{reason: "it was stopped before it finished"}}}
    end

    test "leaves a job that had already finished alone" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)
      :ok = Oban.cancel_job(Repo.get!(Oban.Job, job.id))

      assert {:error, :settled} = Jobs.cancel(job.id)
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
      assert RunHistory.get(record.id).status == "running"
    end

    test "cancels an executing job whose process is gone" do
      # `executing` with nobody registered is a worker that died: there is
      # nothing to ask, so the row is all that is left to cancel.
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)
      :ok = executing(job)

      assert {:ok, :settled} = Jobs.cancel(job.id)

      assert Repo.get!(Oban.Job, job.id).state == "cancelled"

      assert RunHistory.get(record.id).summary["reason"] ==
               "it was stopped before it finished"
    end
  end

  describe "killing a job" do
    test "ends the process, closes the record, and takes the model with it" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)
      :ok = executing(job)

      owner = owner_pid(record.id)
      ref = Process.monitor(owner)

      assert {:ok, :settled} = Jobs.halt(job.id)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      killed = RunHistory.get(record.id)
      assert killed.status == "failed"
      assert killed.summary["reason"] == "someone ended it before it finished"
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end

    test "refuses a job that is not executing" do
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)

      assert {:error, :not_executing} = Jobs.halt(job.id)
      assert Repo.get!(Oban.Job, job.id).state == "available"
    end

    test "settles the record when there was no process to kill" do
      # `executing` and nobody registered: the worker is gone, so there is nothing
      # to kill — but the record it left behind still has to be closed.
      record = record_run()
      {:ok, job} = Jobs.Run.enqueue_run(record)
      :ok = executing(job)

      assert {:ok, :settled} = Jobs.halt(job.id)

      killed = RunHistory.get(record.id)
      assert killed.status == "failed"
      assert killed.summary["reason"] == "someone ended it before it finished"
    end
  end

  # Oban writes `attempted_at` when it starts a job; a job is `executing` from then
  # until an outcome.
  defp executing(job) do
    {1, nil} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempted_at: DateTime.utc_now()]
      )

    :ok
  end

  # A worker, as the registry sees one: a process registered under the run with
  # the model id it is stepping, alive until something kills it. The model id is
  # not a live model, so the stop that follows is asked for and finds nothing.
  defp owner_pid(run_id) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        {:ok, _owner} =
          Registry.register(Monty.Runtime.Registry, {:studio_run, run_id}, "model-1")

        send(parent, {ref, :registered})

        receive do
          :never -> :ok
        end
      end)

    receive do
      {^ref, :registered} -> pid
    after
      1_000 -> flunk("the owner did not register")
    end
  end
end
