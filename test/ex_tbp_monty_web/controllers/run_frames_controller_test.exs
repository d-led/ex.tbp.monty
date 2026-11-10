defmodule ExTbpMontyWeb.RunFramesControllerTest do
  @moduledoc """
  A step's picture, as a browser asks for it.

  The picture is not in the record — a run of twenty thousand steps would not fit
  — so the page asks for the file the run kept, and this is what answers. Two
  checks stand between a request and a path: the run is looked up by id, and the
  path is confined to that run's own directory. A path that is not one of its
  pictures is a 404 however it was spelled.
  """

  use ExTbpMontyWeb.ConnCase

  alias Monty.Studio.{Artifacts, RunHistory}
  alias Monty.Test.Tmp

  # A one-pixel PNG, which is all a test needs of a camera.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

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
    {:ok, name} = Artifacts.put_frame(run.id, 12, "patch", "depth", @png)

    {:ok, run: run, name: name}
  end

  test "sends the picture the run kept, as a PNG", %{conn: conn, run: run, name: name} do
    conn = get(conn, "/runs/#{run.id}/frames/#{name}")

    assert response(conn, 200) == Base.decode64!(@png)
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/png"
  end

  test "says not found for a picture the run does not have", %{conn: conn, run: run} do
    assert conn |> get("/runs/#{run.id}/frames/frames/12/patch-colour.png") |> response(404)
  end

  test "says not found for a run that is not there", %{conn: conn, name: name} do
    missing = Ecto.UUID.generate()
    assert conn |> get("/runs/#{missing}/frames/#{name}") |> response(404)
  end

  test "does not leave the run's directory, however the path is spelled", %{
    conn: conn,
    run: run
  } do
    # Encoded or not, the segments arrive here as a path, and the answer is the
    # same: the file is resolved and then checked to be inside the run's own
    # directory.
    assert conn |> get("/runs/#{run.id}/frames/../run.log") |> response(404)
  end
end
