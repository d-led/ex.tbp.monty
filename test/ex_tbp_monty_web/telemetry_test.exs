defmodule ExTbpMontyWeb.TelemetryTest do
  @moduledoc """
  The dashboard's database numbers are events before they are numbers: a metric
  named `ex_tbp_monty.repo.query.total_time` reads nothing unless a repo publishes
  that name. Ecto's default is the repo module's own name, and this application
  has two compiled repos behind one name (`ExTbpMonty.Repo`), so the default told
  the dashboard about `:repo_postgres` while the metrics listened for `:repo` —
  five rows reading a dash, for every query the instance ever ran.
  """

  use ExTbpMonty.DataCase, async: false

  import Ecto.Query

  alias ExTbpMonty.Repo

  test "a query the pages make is reported under the name the metrics listen on" do
    handler = "repo-query-probe-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ex_tbp_monty, :repo, :query],
      fn _event, _measurements, _metadata, pid -> send(pid, :reported) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Repo.all(from(run in "studio_runs", select: count(run.id)))

    assert_receive :reported
  end
end
