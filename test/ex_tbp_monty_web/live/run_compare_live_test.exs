defmodule ExTbpMontyWeb.RunCompareLiveTest do
  @moduledoc """
  Two runs of one experiment, put beside each other — and the refusal when they
  are not the same experiment.
  """

  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.{Artifacts, RunHistory}
  alias Monty.Test.Tmp

  @experiment "tutorial/dist_agent_5lm_2obj_train"

  # A part's statistics are a file in its own directory, and a test that wrote them
  # into the real one would leave them behind: the folder is this test's own, and
  # `Artifacts.root/0` is where a part's statistics are looked for.
  setup do
    _root = Tmp.env_dir("compare-live", :studio_artifacts_dir)
    :ok
  end

  defp run(attrs) do
    {:ok, run} =
      RunHistory.start(
        Map.merge(
          %{experiment: @experiment, source: "monty", steps: 0, config: %{}},
          attrs
        )
      )

    run
  end

  test "two runs of one experiment, one input apart, are put side by side", %{conn: conn} do
    barrier = run(%{inputs: %{"scheduling" => "barrier"}, summary: %{"steps" => 8595}})
    lagged = run(%{inputs: %{"scheduling" => "lagged"}, summary: %{"steps" => 9000}})

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{barrier.id}&b=#{lagged.id}")

    assert has_element?(view, "#compare-table")
    assert has_element?(view, "#compare-differences", "scheduling")
    assert has_element?(view, "#compare-steps", "8595")
    assert has_element?(view, "#compare-steps", "9000")
  end

  # A lever changes what a step's numbers measure, so a comparison where one side
  # moved it says what that side's numbers mean: two runs of one seed compared
  # without it is a comparison of two different questions.
  test "a side that chose a lever says what its step numbers measured", %{conn: conn} do
    sensors = ~w(vf patch_0 patch_1 patch_2 patch_3)

    serial =
      run(%{
        inputs: %{"sensors" => sensors, "sensors_step" => "serial"},
        summary: %{"steps" => 10}
      })

    concurrent =
      run(%{
        inputs: %{"sensors" => sensors, "sensors_step" => "concurrent"},
        summary: %{"steps" => 10}
      })

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{serial.id}&b=#{concurrent.id}")

    assert has_element?(view, "#compare-shape")
    assert has_element?(view, "#compare-shape", "their sum")
    assert has_element?(view, "#compare-shape", "slowest of them")
  end

  test "two different experiments are refused rather than compared", %{conn: conn} do
    one = run(%{experiment: "tutorial/first_experiment"})
    other = run(%{})

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{one.id}&b=#{other.id}")

    assert has_element?(view, "#compare-refusal")
    refute has_element?(view, "#compare-table")
  end

  test "nothing is compared until two runs are picked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare")

    assert has_element?(view, "#compare-form")
    refute has_element?(view, "#compare-table")
    refute has_element?(view, "#compare-refusal")
  end

  test "the same run twice is refused rather than compared with itself", %{conn: conn} do
    run = run(%{summary: %{"steps" => 8595}})

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{run.id}&b=#{run.id}")

    assert has_element?(view, "#compare-refusal", "same run twice")
    refute has_element?(view, "#compare-table")
  end

  test "a column says when its run has not finished", %{conn: conn} do
    finished = run(%{inputs: %{"scheduling" => "barrier"}, summary: %{"steps" => 8595}})
    running = run(%{inputs: %{"scheduling" => "lagged"}, status: "running"})

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{finished.id}&b=#{running.id}")

    assert has_element?(view, "#compare-table", "running")
  end

  test "a run's own page offers to put it beside another", %{conn: conn} do
    run = run(%{})

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#compare-with[href=\"/compare?a=#{run.id}\"]")
  end

  # A divided run offers its parts in the picker, and two of them can be put side
  # by side: a part has no summary, so both columns are read from the runs'
  # statistics files — the same file format, and the page says so.
  test "two parts of one divided run are put side by side", %{conn: conn} do
    {run, [first, second]} = divided_run()

    write_stats(first["stream"], "correct,14,1.5,11,LM_0,target_in_possible_matches_(TP)")
    write_stats(second["stream"], "time_out,20,2.0,12,LM_0,target_not_matched_(FN)")

    {:ok, view, _html} =
      live(conn, compare_url(picked(run, first), picked(run, second)))

    assert has_element?(view, "#compare-table")
    assert has_element?(view, "#compare-statistics")
    assert has_element?(view, "#compare-table", "part 1 of 2 (eval)")
    assert has_element?(view, "#compare-table", "part 2 of 2 (eval)")
    assert has_element?(view, "#compare-differences", "part")
    assert has_element?(view, "#compare-steps", "14")
    assert has_element?(view, "#compare-steps", "20")
    assert has_element?(view, "#compare-lm-0-matched", "1")
  end

  test "a run that was not divided says so rather than comparing a part of it", %{conn: conn} do
    whole = run(%{})
    {divided, [_first, second]} = divided_run()

    {:ok, view, _html} =
      live(conn, compare_url(whole.id <> "|eval|0", picked(divided, second)))

    assert has_element?(view, "#compare-refusal", "not divided into parts")
    refute has_element?(view, "#compare-table")
  end

  # A part performed on another node keeps its statistics there, and a part still
  # running has not written them yet. Either way the page says that, rather than
  # drawing a column of zeros.
  test "a part with no statistics to read is refused in words", %{conn: conn} do
    {run, [first, second]} = divided_run()

    {:ok, view, _html} =
      live(conn, compare_url(picked(run, first), picked(run, second)))

    assert has_element?(view, "#compare-refusal", "no statistics to read here yet")
    refute has_element?(view, "#compare-table")
  end

  # Picking is what a reader does; the URL is only where the pick is kept. Choosing
  # a part on each side patches to the two of them and draws the table.
  test "picking two parts in the form draws them side by side", %{conn: conn} do
    {run, [first, second]} = divided_run()

    write_stats(first["stream"], "correct,14,1.5,11,LM_0,target_in_possible_matches_(TP)")
    write_stats(second["stream"], "time_out,20,2.0,12,LM_0,target_not_matched_(FN)")

    {:ok, view, _html} = live(conn, ~p"/compare")

    view
    |> element("#compare-form")
    |> render_change(%{"picked" => %{"a" => picked(run, first), "b" => picked(run, second)}})

    assert_patch(view, compare_url(picked(run, first), picked(run, second)))
    assert has_element?(view, "#compare-table", "part 1 of 2 (eval)")
  end

  # A run divided into two parts, as its record keeps the plan
  # (`Monty.Studio.Partition`): the waves' parts are numbered from one, so a part
  # is a run, a wave and a number.
  defp divided_run do
    parts =
      for index <- 0..1 do
        %{
          "index" => index,
          "of" => 2,
          "phase" => "eval",
          "stream" => Ecto.UUID.generate(),
          "phases" => %{"eval" => [index * 2, index * 2 + 1]}
        }
      end

    {run(%{inputs: %{"parts" => parts}, summary: %{"steps" => 0}}), parts}
  end

  defp picked(run, part), do: "#{run.id}|#{part["phase"]}|#{part["index"]}"

  # The header of a pick is percent-encoded like any other query value: the
  # separator is this page's, not a browser's.
  defp compare_url(a, b), do: "/compare?" <> URI.encode_query(%{"a" => a, "b" => b})

  # The statistics a part wrote into its own directory, with the columns the
  # reader needs: what the module concluded, what it cost, and which episode it
  # was.
  defp write_stats(stream, row) do
    dir = Artifacts.dir(stream)
    File.mkdir_p!(dir)

    header = "primary_performance,num_steps,time,episode_seed,lm_id,TFNP\n"
    File.write!(Path.join(dir, "eval_stats.csv"), header <> row <> "\n")
  end
end
