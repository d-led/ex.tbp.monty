defmodule Monty.Studio.Jobs.ReaperTest do
  @moduledoc """
  A record says `running` until something closes it, and the job that executes a
  run is the only thing that can. When the job dies with its node nothing is left
  to close the record, so the record keeps saying `running` to every page and to
  every attempt to start the experiment again.

  These tests are about the two facts a live run cannot fake: a process
  registered for it, and a job still waiting its turn. Everything else is a run
  whose process is gone.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  import Ecto.Query

  alias ExTbpMonty.Repo
  alias Monty.Studio.{Artifacts, Jobs, RunHistory}
  alias Monty.Studio.Jobs.Reaper
  alias Monty.Test.Tmp

  @abandoned "it stopped before it finished — nothing was working on it any more"

  setup do
    Tmp.env_dir("studio-runs", :studio_artifacts_dir)
    :ok
  end

  defp start_run do
    {:ok, record} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: 2,
        config: %{"experiment" => %{"config" => %{}}},
        inputs: %{}
      })

    record
  end

  defp enqueue(record) do
    {:ok, job} = Jobs.Run.enqueue_run(record)
    job
  end

  # The row a node leaves behind when it dies mid-run: Oban still has the job
  # `executing`, because noticing is somebody else's job and in this application
  # nobody else's job was anybody's.
  defp executing_since(job, seconds) do
    attempted_at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, nil} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempted_at: attempted_at]
      )

    :ok
  end

  describe "a run whose job is still waiting" do
    test "is not abandoned: it is a run that has not started yet" do
      record = start_run()
      _job = enqueue(record)

      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "running"
    end
  end

  describe "a run whose job has settled" do
    test "is closed, with the reason a person can act on" do
      record = start_run()
      job = enqueue(record)
      :ok = Oban.cancel_job(job)

      assert Reaper.sweep() == 1

      closed = RunHistory.get(record.id)
      assert closed.status == "failed"
      assert closed.summary["reason"] == @abandoned
      assert closed.finished_at
    end

    test "says so in its own log, which exists even though the run never made one" do
      record = start_run()
      job = enqueue(record)
      :ok = Oban.cancel_job(job)

      _ = Reaper.sweep()

      log = File.read!(Artifacts.log_path(record.id))
      assert log =~ "the run was abandoned"
      assert log =~ @abandoned
    end

    test "tells the page that was watching it, rather than leaving it waiting" do
      record = start_run()
      job = enqueue(record)
      :ok = Oban.cancel_job(job)
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))

      _ = Reaper.sweep()

      assert_received {:studio, _run_id, {:failed, %{reason: @abandoned}}}
    end

    test "says what the job itself recorded, when it recorded anything" do
      # A worker that raised leaves its exception on the attempt, and that
      # sentence names the cause; "the process is gone" would be true and
      # useless.
      record = start_run()
      job = enqueue(record)

      {1, nil} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
          set: [
            state: "discarded",
            errors: [%{"error" => "** (RuntimeError) the world would not start\n    stack"}]
          ]
        )

      _ = Reaper.sweep()

      assert RunHistory.get(record.id).summary["reason"] ==
               "** (RuntimeError) the world would not start"
    end
  end

  describe "a run whose job never existed" do
    test "is closed too: nothing was ever going to run it" do
      record = start_run()

      assert Reaper.sweep() == 1
      assert RunHistory.get(record.id).status == "failed"
    end
  end

  describe "a run a process is working on" do
    test "is left alone, whatever its job says" do
      record = start_run()

      {:ok, _owner} =
        Registry.register(Monty.Runtime.Registry, {:studio_run, record.id}, :starting)

      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "running"
    end
  end

  describe "a job left executing" do
    test "is given a minute before its silence counts as death" do
      # A worker registers itself first thing, but Oban's `attempted_at` is
      # written before the worker runs at all: judging inside that gap would
      # close a run that is just starting.
      record = start_run()
      job = enqueue(record)
      :ok = executing_since(job, 5)

      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "running"
    end

    test "is abandoned once nobody has claimed it, and its job is cancelled" do
      record = start_run()
      job = enqueue(record)
      :ok = executing_since(job, 300)

      assert Reaper.sweep() == 1
      assert RunHistory.get(record.id).status == "failed"
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end
  end
end
