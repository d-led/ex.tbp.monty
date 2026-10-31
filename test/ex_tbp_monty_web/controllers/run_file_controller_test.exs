defmodule ExTbpMontyWeb.RunFileControllerTest do
  @moduledoc """
  A run's file, as a browser asks for it.

  Two checks stand between a request and a path: the run is looked up by id, and
  the name is matched against the files that run's directory holds. Both are
  asserted from the outside here — a name that is not one of the run's files is a
  404, however it was spelled.
  """

  use ExTbpMontyWeb.ConnCase

  alias Monty.Studio.{Artifacts, RunHistory}
  alias Monty.Test.Tmp

  setup do
    Tmp.env_dir("studio-runs", :studio_artifacts_dir)

    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: 1,
        seed: 42,
        config: %{},
        inputs: %{}
      })

    :ok = Artifacts.start(run.id)

    File.write!(
      Path.join(Artifacts.dir(run.id), "eval_stats.csv"),
      "episode,performance\n0,correct\n"
    )

    {:ok, run: run}
  end

  test "sends the file a run wrote, as the file it is", %{conn: conn, run: run} do
    conn = get(conn, "/runs/#{run.id}/files/eval_stats.csv")

    assert response(conn, 200) == "episode,performance\n0,correct\n"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/csv"
  end

  test "a file the run does not hold is not found, however it is spelled", %{conn: conn, run: run} do
    assert conn |> get("/runs/#{run.id}/files/../run.log") |> response(404)
    assert conn |> get("/runs/#{run.id}/files/config_snapshot.yaml") |> response(404)
    assert conn |> get("/runs/#{run.id}/files/run.log") |> response(404)
  end

  test "a run that does not exist has no files", %{conn: conn} do
    missing = Ecto.UUID.generate()

    assert conn |> get("/runs/#{missing}/files/eval_stats.csv") |> response(404)
  end
end
