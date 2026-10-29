defmodule ExTbpMontyWeb.JobsLiveTest do
  @moduledoc """
  The queue page: a job you can see, and the run it belongs to.

  The point of the page is the link: a queued run has no results yet, so the
  only way to tell it apart from a run that never happened is to see its job and
  follow it to its record.
  """

  use ExTbpMontyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Monty.Studio.{Jobs, RunHistory, RunLog}

  defp record_run do
    {:ok, opened} = Monty.Studio.open("tutorial/first_experiment")
    {:ok, record} = RunHistory.start(RunLog.attributes(opened, 3))
    record
  end

  test "an empty queue says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#jobs-empty")
    assert has_element?(view, "#refresh")
  end

  test "a queued run is shown with its state and a link to its record", %{conn: conn} do
    record = record_run()
    {:ok, job} = Jobs.Run.enqueue_run(record)

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#job-#{job.id}")
    assert has_element?(view, "#job-#{job.id} a[href='/runs/#{record.id}']")
    assert render(view) =~ "available"
    assert render(view) =~ "running"
  end

  test "a job whose run was deleted still appears, without a link", %{conn: conn} do
    record = record_run()
    {:ok, job} = Jobs.Run.enqueue_run(record)
    {:ok, _deleted} = RunHistory.delete(record)

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#job-#{job.id}")
    assert render(view) =~ "deleted"
    refute has_element?(view, "#job-#{job.id} a")
  end

  test "refreshing picks up a job enqueued after the page opened", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/jobs")
    assert html =~ "The queue is empty."

    record = record_run()
    {:ok, job} = Jobs.Run.enqueue_run(record)

    refute has_element?(view, "#job-#{job.id}")

    view |> element("#refresh") |> render_click()

    assert has_element?(view, "#job-#{job.id}")
  end
end
