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

  # A run whose worker has it: the record says `queued` until somebody claims it.
  defp start_run do
    {:ok, running} = queue_run() |> RunHistory.mark_running()
    running
  end

  # A run that has been asked for and not claimed.
  defp queue_run do
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

  # A run nobody has written to for a while: the other half of "nothing is
  # working on it", now that a record still being written counts as a worker.
  defp quiet_since(record, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, nil} =
      Repo.update_all(from(r in RunHistory.Run, where: r.id == ^record.id),
        set: [updated_at: at]
      )

    record
  end

  describe "a run being stepped somewhere this node cannot see" do
    test "is left alone while its record is still being written" do
      # `mix monty.run` steps in its own VM: no process this registry holds, no
      # job in this queue. Its record moving is the only evidence it exists, and
      # judging it by absence used to close a healthy run at the first page visit.
      record = start_run()
      {:ok, _stepped} = RunHistory.record_step(record, %{"step" => 0}, %{})

      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "running"
    end

    test "is abandoned once it has been silent for a minute" do
      record = start_run()
      _quiet = quiet_since(record, 61)

      assert Reaper.sweep() == 1
      assert RunHistory.get(record.id).status == "failed"
    end
  end

  describe "a run whose job is still waiting" do
    test "is not abandoned: it is a run that has not started yet" do
      record = queue_run()
      _job = enqueue(record)

      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "queued"
    end
  end

  describe "a run whose job has settled" do
    test "is closed at once, however recently its record was written" do
      # A cancelled or discarded job will never step the run again. Waiting for
      # the record to go quiet first is a minute of a page saying `running`
      # about a run that died with its node, on every reload.
      record = start_run()
      job = enqueue(record)
      :ok = Oban.cancel_job(job)

      assert Reaper.sweep() == 1
      assert RunHistory.get(record.id).status == "failed"
    end

    test "is closed, with the reason a person can act on" do
      record = start_run()
      job = enqueue(record)
      :ok = Oban.cancel_job(job)
      _quiet = quiet_since(record, 61)

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
      _quiet = quiet_since(record, 61)

      _ = Reaper.sweep()

      log = File.read!(Artifacts.log_path(record.id))
      assert log =~ "the run was abandoned"
      assert log =~ @abandoned
    end

    test "tells the page that was watching it, rather than leaving it waiting" do
      record = start_run()
      job = enqueue(record)
      :ok = Oban.cancel_job(job)
      _quiet = quiet_since(record, 61)
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
      _quiet = quiet_since(record, 61)

      {1, nil} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
          set: [
            state: "discarded",
            errors: [%{"error" => "** (RuntimeError) the world would not start\n    stack"}]
          ]
        )

      _ = Reaper.sweep()

      # The sentence is the answer; the banner it came from is the detail, kept
      # beside it rather than printed at whoever opens the run.
      kept = RunHistory.get(record.id).summary

      assert kept["reason"] == "the world would not start"
      assert kept["technical"] =~ "** (RuntimeError) the world would not start"
    end
  end

  describe "a run whose job never existed" do
    test "is closed too: nothing was ever going to run it" do
      record = start_run()
      _quiet = quiet_since(record, 61)

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
    test "is abandoned at once when no process is stepping it" do
      # The run died with the node it was started on, and Oban's job still says
      # `executing` until its rescuer gets to it. A record written seconds before
      # that is the previous node's last breath, not a worker: what says nobody is
      # working on the run is that no pid is.
      record = start_run()
      job = enqueue(record)
      :ok = executing_since(job, 300)

      assert Reaper.sweep() == 1
      assert RunHistory.get(record.id).status == "failed"
    end

    test "is left alone while a pid is stepping it" do
      record = start_run()
      job = enqueue(record)
      :ok = executing_since(job, 3_600)

      {:ok, _owner} =
        Registry.register(Monty.Runtime.Registry, {:studio_run, record.id}, :running)

      # This test process is the owner, and it is alive: that is the whole of it.
      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "running"
    end

    test "is left alone in the moment between Oban claiming it and its worker registering" do
      # Oban writes `attempted_at` before it calls the worker, and the worker
      # registers itself first thing: judging inside that gap would close a run
      # that is just starting.
      record = start_run()
      job = enqueue(record)
      :ok = executing_since(job, 0)

      assert Reaper.sweep() == 0
      assert RunHistory.get(record.id).status == "running"
    end

    test "is abandoned once nobody has claimed it, and its job is cancelled" do
      record = start_run()
      job = enqueue(record)
      :ok = executing_since(job, 300)
      _quiet = quiet_since(record, 300)

      assert Reaper.sweep() == 1
      assert RunHistory.get(record.id).status == "failed"
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end
  end

  describe "the one-run form a page polls with" do
    # Twice a second, for as long as a page is open, so what it reads matters: a
    # full record is the run's whole transcript and — before the record is read
    # without them — its pictures, which on a long run is most of a gigabyte.
    test "asks the counters and not the run's transcript" do
      record = start_run()
      {:ok, _stepped} = RunHistory.record_step(record, %{"step" => 0}, %{})

      asked = queries_while(fn -> assert Reaper.reap(record.id) == false end)

      assert asked != []
      refute Enum.any?(asked, &(&1 =~ "timeline"))
      refute Enum.any?(asked, &(&1 =~ "r0.log"))
    end

    test "still closes a run nothing is working on" do
      record = start_run()
      _quiet = quiet_since(record, 61)

      assert Reaper.reap(record.id) == :ok
      assert RunHistory.get(record.id).status == "failed"
    end
  end

  # The statements the repository ran while this block did its work. Asked of
  # telemetry so a test can say *what* was read, which is the question here.
  defp queries_while(work) do
    id = "reaper-queries-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      id,
      [[:ex_tbp_monty, :repo, :postgres, :query], [:ex_tbp_monty, :repo, :query]],
      fn _event, _measurements, metadata, pid -> send(pid, {:query, id, metadata.query}) end,
      test
    )

    work.()

    statements = collect_queries(id)
    :telemetry.detach(id)
    statements
  end

  defp collect_queries(id) do
    receive do
      {:query, ^id, statement} -> [statement | collect_queries(id)]
    after
      0 -> []
    end
  end

  # With one runs table for a cluster, every node sees every open row, and the
  # registry a run is held in is the stepping node's own. So "nothing is working on
  # it" has to be asked only about this node's runs, and about a node that has
  # gone — never about a peer that is answering. (Two parallel runs, and the one
  # stepped by the other node was abandoned at step 95: this is that case.)
  describe "whose run it is" do
    test "another node's run is not this node's to close, whether it answers or not" do
      # The clause that used to allow this — "and the node is not in the cluster" —
      # rested on a 500 ms probe, and two runs saturating one machine made it time
      # out: node1 "knew" node2 had gone and abandoned its live run, twice. A run
      # is not worth a guess about liveness.
      assert Reaper.ours?(%{node: "node2@127.0.0.1"}, ["node1@127.0.0.1"]) == false

      assert Reaper.ours?(%{node: "node2_127.0.0.1"}, ["node1_127.0.0.1", "node1@127.0.0.1"]) ==
               false
    end

    test "a run this node has, and one that names no node, are both this node's" do
      assert Reaper.ours?(%{node: "node1_127.0.0.1"}, ["node1_127.0.0.1", "node1@127.0.0.1"])
      assert Reaper.ours?(%{node: nil}, [])
    end
  end
end
