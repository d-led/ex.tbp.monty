defmodule ExTbpMontyWeb.ExperimentDividedRunTest do
  @moduledoc """
  A page opened on a divided run.

  A divided run writes its steps to one stream per part, and a late page reads the
  run's own stream — which a divided run does not write. So a page opened two
  steps into such a run used to show nothing until the next broadcast, and a page
  opened after many steps showed only what was announced while it was open.

  These cases are the page's side of `Monty.Studio.CatchUp`: that a page opened
  mid-run draws the steps its parts took before it opened, and that opening one
  twice draws each step once.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Monty.Studio.{RunHistory, RunStream}

  @experiment "base_config_10distinctobj_dist_agent"

  setup do
    _root = Monty.Test.Tmp.env_dir("studio-divided-page", :studio_artifacts_dir)
    :ok
  end

  describe "a page opened on a divided run that is still stepping" do
    test "draws the steps its parts took before it opened", %{conn: conn} do
      record = stepping_run([[0], [1]])
      [first, second] = record.inputs["parts"]

      RunStream.publish(first["stream"], step(0, 0))
      RunStream.publish(first["stream"], step(1, 0))
      RunStream.publish(second["stream"], step(0, 1))

      {:ok, view, _html} = live(conn, ~p"/experiments/#{@experiment}")

      # The page adopts the run at mount and asks on its own clock: one poll is a
      # page opened and settled, which is the moment a reader sees.
      send(view.pid, :studio_poll)

      # Three steps, from two streams this node holds, in the run's order — the
      # run's own stream is empty, so a page that read only that drew nothing.
      assert lines(view) == ["log-1", "log-2", "log-3"]

      # And a second poll asks again from where it stopped and draws nothing
      # twice: the cursors are the whole reason this is affordable.
      send(view.pid, :studio_poll)
      assert lines(view) == ["log-1", "log-2", "log-3"]
    end
  end

  defp lines(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#run-log li[id^='log-']")
    |> LazyHTML.attribute("id")
  end

  # A divided run this node is stepping: two parts, its own row saying `running`.
  defp stepping_run(episodes_per_part) do
    parts =
      episodes_per_part
      |> Enum.with_index()
      |> Enum.map(fn {episodes, index} ->
        %{
          "index" => index,
          "of" => length(episodes_per_part),
          "phase" => "eval",
          "stream" => Ecto.UUID.generate(),
          "phases" => %{"eval" => episodes}
        }
      end)

    {:ok, record} =
      RunHistory.start(%{
        experiment: @experiment,
        source: "monty",
        steps: 5,
        seed: 42,
        config: %{},
        inputs: %{"seed" => 42, "world" => "synthetic", "parallel" => 2, "parts" => parts}
      })

    {:ok, record} = RunHistory.mark_running(record)
    record
  end

  # A step as the run's worker hands it over: the report `RunStream.publish/2`
  # turns into the line the page draws.
  defp step(number, episode) do
    %{
      info: %{
        step: number,
        percept_ids: [],
        inputs: %{},
        votes: %{sent: 0, used: 0},
        goals: 0,
        actions: [],
        duration_us: 1
      },
      at: Monty.Studio.RunLog.now().instant,
      episode: episode,
      beliefs: %{},
      observations: %{},
      sensor_ids: [],
      centre: nil
    }
  end
end
