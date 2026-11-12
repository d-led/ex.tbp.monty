defmodule ExTbpMontyWeb.RunHistoryLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Monty.Studio.RunHistory

  # A run as a finished experiment leaves it, in whatever state a test needs.
  defp insert_run(%{experiment: experiment, status: status}) do
    {:ok, run} =
      RunHistory.start(%{experiment: experiment, source: "monty", steps: 0, config: %{}})

    if status == "running" do
      # A record only says `running` once a worker has it, so a test that wants a
      # run under way has to say so the same way the worker does.
      {:ok, running} = RunHistory.mark_running(run)
      running
    else
      {:ok, closed} = RunHistory.finish(run, %{"reason" => "as the test asked"}, status)
      closed
    end
  end

  # A job Oban has started: `executing` from `attempted_at` until an outcome.
  defp running(job) do
    {1, nil} =
      ExTbpMonty.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempted_at: DateTime.utc_now()]
      )

    :ok
  end

  # What the worker publishes: the run's id says which page it is for, so a
  # page showing one run ignores another's steps.
  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      Monty.Studio.Jobs.Run.topic(run_id),
      {:studio, run_id, event}
    )
  end

  setup do
    # Counting runs is what most of this module asserts, and the table survives
    # between local runs: a page that says "1–25 of 27" is worth testing on a
    # history the test built itself.
    ExTbpMonty.Repo.delete_all(RunHistory.Run)

    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: 2,
        seed: 42,
        config: %{"experiment" => %{"config" => %{"seed" => 42}}},
        inputs: %{"groups" => %{"monty/learning_module" => "displacement_1lm"}, "seed" => 42}
      })

    {:ok, run} =
      RunHistory.record_step(
        run,
        %{
          "step" => 0,
          "at" => Monty.Studio.RunLog.now().instant,
          "goals" => 1,
          "votes" => %{"sent" => 1, "used" => 1},
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "actions" => 1,
          "duration_us" => 120
        },
        moment(0)
      )

    {:ok, run} =
      RunHistory.record_step(
        run,
        %{
          "step" => 1,
          "at" => Monty.Studio.RunLog.now().instant,
          "goals" => 0,
          "votes" => %{"sent" => 1, "used" => 1},
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "actions" => 1,
          "duration_us" => 140
        },
        moment(1)
      )

    {:ok, run} = RunHistory.finish(run, %{"steps" => 2, "votes_used" => 2})

    {:ok, run: run}
  end

  # A record nobody has written to for a while: a fresh record gets a minute's
  # grace, because a worker elsewhere may not have written its first step yet.
  defp quiet_since(record, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    ExTbpMonty.Repo.update_all(
      from(r in RunHistory.Run, where: r.id == ^record.id),
      set: [updated_at: at]
    )

    record
  end

  # A step handed to the stream, the way a worker hands one over: the worker does
  # not write the row per step, so this is the only place the page can learn of
  # a step until the run's next episode boundary. The entry and the line are the
  # stream's to derive from the report.
  defp publish(run_id, step) do
    Monty.Studio.RunStream.publish(run_id, report(step, %{}))
  end

  # A step that says what a learning module made of it. Beliefs are what the
  # per-object chart is drawn from, so a run has that chart only once one
  # arrives — which is the state this file's records are not in.
  defp publish_beliefs(run_id, step, object) do
    beliefs = %{"learning_module_0" => %{"graphs" => %{object => %{"max_evidence" => 5.0}}}}

    Monty.Studio.RunStream.publish(run_id, report(step, beliefs))
  end

  defp report(step, beliefs) do
    %{
      info: %{
        step: step,
        percept_ids: [:patch],
        inputs: %{learning_module_0: 1},
        votes: %{sent: 1, used: 1},
        goals: 0,
        actions: [:turn_left],
        duration_us: 140
      },
      at: Monty.Studio.RunLog.now().instant,
      episode: 0,
      beliefs: beliefs,
      observations: %{},
      sensor_ids: [],
      centre: nil
    }
  end

  # The picture is the server's, but the gestures are the browser's: one hook
  # (`assets/js/chart.js`) serves this chart and the experiment page's, and it
  # reads the window, the size and — the part that rots — the *names* of the
  # events it must push out of data attributes. Rename one of those and no
  # picture changes and no other test fails: the chart just stops answering the
  # wheel. So the contract is asserted here, and the behaviour is driven through
  # the names the markup gives it rather than the names this test knows.
  describe "the gesture hook's contract with the chart" do
    test "the chart is drawn for the window it says it is drawing", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-chart-zoom[phx-hook=ChartZoom]")
      assert has_element?(view, "#replay-chart-zoom[data-width][data-height]")

      from = told_the_hook(view, "data-x-min")
      to = told_the_hook(view, "data-x-max")

      assert view |> element("#replay-chart-window") |> render() =~ "steps #{from}–#{to}"
    end

    test "and answers the events it is told to push", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The whole run, then one step of it: a chart that ignores either name
      # keeps drawing the window it opened on, which is the failure this is for.
      render_hook(view, told_the_hook(view, "data-zoom-all-event"), %{"how" => "all"})
      render_hook(view, told_the_hook(view, "data-zoom-event"), %{"from" => 1, "to" => 1})

      assert view |> element("#replay-chart-window") |> render() =~ "steps 1–1"
      assert has_element?(view, "#replay-chart-zoom[data-x-min='1'][data-x-max='1']")
    end
  end

  # What the markup tells the gesture hook, read out of the page: a renamed
  # attribute is then what fails the test, not an assumption about it.
  defp told_the_hook(view, attribute) do
    view
    |> element("#replay-chart-zoom")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  describe "the chart a run is opened on" do
    test "is every object once the run has one, with nobody choosing it",
         %{conn: conn, run: run} do
      publish_beliefs(run.id, 0, "mug")
      publish_beliefs(run.id, 1, "mug")
      publish_beliefs(run.id, 2, "mug")
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-chart-title") |> render() =~ "every object"
    end
  end

  # The write at an episode boundary rewrites the run's transcript, so it can
  # take longer than the page's idea of a slow step. A run in that state is
  # working, not stalled, and the page has to be able to say which.
  # The plot is a set of click targets before it is a picture: every interaction
  # the hook used to capture is an ordinary LiveView event now, so what a click
  # means is testable without a browser.
  describe "clicking the plot" do
    test "seeks to the step under the pointer, with no hook involved", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-chart-columns #replay-column-47")

      html = view |> element("#replay-column-47") |> render_click()

      assert html =~ "step 1"
    end

    test "and full screen leaves on Escape, as a full screen anything does",
         %{conn: conn, run: run} do
      publish_beliefs(run.id, 0, "mug")
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The key is the browser's: the page can only say it listens for it on the
      # window and which key it means. Without these two attributes the event
      # below would still pass while a reader's Escape did nothing — which is the
      # difference this assertion exists for.
      panel = view |> element("#replay-panel") |> render()

      assert panel =~ ~s(phx-window-keydown="replay_collapse")
      assert panel =~ ~s(phx-key="Escape")

      view |> element("#replay-expand") |> render_click()

      assert view |> element("#replay-chart-panel") |> render() =~ ~s(data-fullscreen="true")

      view |> element("#replay-panel") |> render_keydown(%{"key" => "Escape"})

      refute view |> element("#replay-chart-panel") |> render() =~ ~s(data-fullscreen="true")
    end

    test "and each band says which episode it is, without painting a handle under it",
         %{conn: conn, run: run} do
      publish_beliefs(run.id, 0, "mug")
      publish_beliefs(run.id, 1, "mug")
      publish_beliefs(run.id, 2, "mug")
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The band is a tint of the object's colour across the plot, and that is
      # all it is: the strip of handles along the foot was a second row of
      # coloured blocks under an axis nobody asked them to sit under.
      band = view |> element("#replay-chart") |> render()

      assert band =~ ~s(class="episode-band")
      assert band =~ ~s(data-episode="0")
      refute band =~ "replay-episode-0"
    end
  end

  describe "a run that is writing an episode back" do
    test "says it is saving rather than that it is not progressing", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      send(view.pid, {:studio, run.id, {:keeping, 22_508}})

      assert view |> element("#run-keeping") |> render() =~ "saving 22508 steps to the database"
      refute has_element?(view, "#run-stalled")

      send(view.pid, {:studio, run.id, :kept})

      refute has_element?(view, "#run-keeping")
    end
  end

  # The two numbers a person asks of a run: when it began, and how long it has
  # taken. The experiment page already says them for the run it is watching
  # ("running 1 m 36 s since 23:33:19"); the run's own page is where a reader
  # goes to check, so it says the same thing.
  describe "when a run began, and how long it took" do
    test "a run that is still stepping says how long, and since when", %{conn: conn} do
      run = insert_run(%{experiment: "tutorial/first_experiment", status: "running"})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      timing = view |> element("#run-timing") |> render()

      assert timing =~ "running for"
      assert timing =~ "since"
      # The clock is the `LocalTime` component's, so the browser is what turns
      # UTC into the reader's own time.
      assert timing =~ "<time"
    end

    test "a run that has stopped says what it took, and between which clocks", %{conn: conn} do
      run = insert_run(%{experiment: "tutorial/first_experiment", status: "finished"})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      timing = view |> element("#run-timing") |> render()

      assert timing =~ "took"
      assert timing =~ "from"
      assert timing =~ "to"
      assert length(String.split(timing, "<time")) == 3, "the start and the end, both as clocks"
    end
  end

  describe "a run that is still stepping" do
    test "is counted from memory, and is not called stalled", %{conn: conn} do
      # The row is written at an episode boundary, so during an episode it says
      # what it said before the episode began. A header reading the row would
      # say "0 steps · nothing recorded for a minute — not progressing" about a
      # run that is stepping, which is the page lying about the one thing it is
      # for.
      {:ok, run} =
        RunHistory.start(%{
          experiment: "tutorial/first_experiment",
          source: "monty",
          steps: 100,
          inputs: %{"episodes" => 1}
        })

      publish(run.id, 0)
      publish(run.id, 1)
      publish(run.id, 2)
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")

      assert html =~ "3 steps"
      refute html =~ "not progressing"
    end

    # The page asks the record how the run is doing twice a second, and the
    # record is written at an episode boundary: a page that took the steps from
    # it too would lose the ones it was already showing every time it looked —
    # and the counters it asks for are not the only thing on the page that came
    # from the row. What the run was given and run with is written once, when it
    # starts, so a poll has to keep it rather than read `nil` over it.
    test "keeps the steps it was handed while it asks how the run is doing",
         %{conn: conn} do
      {:ok, run} =
        RunHistory.start(%{
          experiment: "tutorial/first_experiment",
          source: "monty",
          steps: 100,
          inputs: %{"episodes" => 1}
        })

      publish(run.id, 0)
      publish(run.id, 1)
      publish(run.id, 2)
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-panel") |> render() =~ "steps 0–2"
      assert view |> element("#run-inputs") |> render() =~ "episodes"

      send(view.pid, :show_poll)

      assert view |> element("#replay-panel") |> render() =~ "steps 0–2"
      assert view |> element("#run-inputs") |> render() =~ "episodes"
      assert has_element?(view, "#log-0-0")
    end

    # The reason the step path exists: a step the worker publishes is in memory on
    # this node, so showing it must not ask the database anything. A page that
    # read the record per step competed with the run it was watching — the reason
    # the whole path was rewritten — and this is the one assertion that notices
    # the difference without measuring time.
    test "a step costs the database nothing", %{conn: conn} do
      {:ok, queued} =
        RunHistory.start(%{
          experiment: "tutorial/first_experiment",
          source: "monty",
          steps: 100,
          inputs: %{"episodes" => 1}
        })

      # A run someone is stepping: the page's question about it is the cheap one
      # only while it has a worker.
      {:ok, run} = RunHistory.mark_running(queued)

      publish(run.id, 0)
      publish(run.id, 1)
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # Everything the page needed to draw itself is read now; what follows is one
      # step of a run it is already showing. The counter is proved against a read
      # that certainly happens, so a wrong event name cannot pass for "no reads".
      assert count_queries(fn -> RunHistory.head(run.id) end) > 0

      count =
        count_queries(fn ->
          publish(run.id, 2)
          send(view.pid, {:studio, run.id, {:step, %{step: 2}}})
          send(view.pid, :refresh_due)
          _ = :sys.get_state(view.pid)
        end)

      assert view |> element("#replay-panel") |> render() =~ "steps 0–2"
      assert count == 0
    end
  end

  # How many statements the repository ran while this block did its work: asked of
  # telemetry, because the question is whether the page asked the database, not
  # what it asked.
  defp count_queries(work) do
    id = "queries-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      id,
      [[:ex_tbp_monty, :repo, :postgres, :query], [:ex_tbp_monty, :repo, :query]],
      fn _event, _measurements, _metadata, pid -> send(pid, {:query, id}) end,
      test
    )

    work.()

    counted = count_sent(id)
    :telemetry.detach(id)
    counted
  end

  defp count_sent(id) do
    receive do
      {:query, ^id} -> 1 + count_sent(id)
    after
      0 -> 0
    end
  end

  describe "what a row says a run did" do
    test "the steps and episodes it stepped, not the budget it was allowed", %{conn: conn} do
      # The run in question: allowed 500 steps an episode, given all 140 episodes
      # of the experiment, it recognised its object and stopped after three steps
      # in two of them. The old row said "500" — a number that never happened.
      {:ok, run} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 500,
          inputs: %{"episodes" => 140}
        })

      run =
        Enum.reduce([{0, 0}, {0, 1}, {1, 0}], run, fn {episode, step}, run ->
          {:ok, next} =
            RunHistory.record_step(run, %{"step" => step, "episode" => episode}, moment(step))

          next
        end)

      {:ok, run} =
        RunHistory.finish(run, %{"steps" => 3, "outcome" => %{"learning_module_0" => "match"}})

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert view |> element("#steps-#{run.id}") |> render() =~ "3"
      assert view |> element("#episodes-#{run.id}") |> render() =~ "ep 2/140"
      assert view |> element("#ending-#{run.id}") |> render() =~ "recognised"
    end
  end

  # A step's moment, recorded the way a run records one: the arrays a camera
  # answers with go in, and the pictures a page draws them into come out. The
  # depth grows with the step, so a step is visibly a different step.
  defp moment(step) do
    near = 0.02 + step * 0.01

    Monty.Studio.RunLog.moment(%{step: step}, %{
      Monty.Simulators.Synthetic.Environment.agent_id() => %{
        "patch" => %{
          "location" => [step * 0.01, 0.0, 0.1],
          "value" => 0.0,
          "depth" => [[near, near + 0.02], [near, near + 0.02]],
          "rgba" => [[[0.2, 0.7, 0.2, 1.0]], [[0.2, 0.7, 0.2, 1.0]]]
        }
      }
    })
  end

  # A run that is still going: a page follows one of these, where a finished run
  # is read once and stays still.
  defp running_run(steps) do
    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: 10,
        seed: 42,
        config: %{},
        inputs: %{}
      })

    Enum.reduce(0..(steps - 1)//1, run, &record_step(&2, &1))
  end

  defp record_step(run, step) do
    {:ok, run} =
      RunHistory.record_step(
        run,
        %{
          "step" => step,
          "at" => Monty.Studio.RunLog.now().instant,
          "goals" => 1,
          "votes" => %{"sent" => 1, "used" => 1},
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "actions" => 1,
          "duration_us" => 120
        },
        moment(step)
      )

    run
  end

  # The log lines the page is holding, oldest first: the window it follows, which
  # is not the run's whole transcript.
  defp log_lines(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(li[id^="log-0-"]))
    |> LazyHTML.attribute("id")
  end

  # What the chart carries for the hover to read: one entry per drawn point, with
  # the object it belongs to, the step, what that step was worth, and the unit.
  # The page sends the words once and the numbers per point, so this puts back the
  # shape these tests read — the same shape the hook puts back.
  defp samples(view) do
    payload =
      view
      |> element("#replay-chart-hover")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-samples")
      |> hd()
      |> Jason.decode!()

    Enum.map(payload["points"], fn [line, x, y, step, value] ->
      %{
        "line" => Enum.at(payload["lines"], line),
        "x" => x,
        "y" => y,
        "step" => step,
        "value" => value,
        "unit" => payload["unit"],
        "named" => payload["named"]
      }
    end)
  end

  # The words on the value axis, top to bottom.
  defp axis_labels(axis) do
    ~r/>\s*(-?\d+(?:\.\d+)?)\s*</
    |> Regex.scan(axis, capture: :all_but_first)
    |> List.flatten()
  end

  # Where each element sits in the page, in characters — the order a reader
  # scrolls through them, which is a property of the page and not of a template.
  defp order_in_page(html, ids) do
    Enum.map(ids, fn id ->
      {at, _length} = :binary.match(html, ~s{id="#{id}"})
      at
    end)
  end

  # A finished run that kept what its modules believed: one graph per object,
  # with the strongest evidence the module held for it. This is the shape the
  # chart of every object is drawn from. One map is one step; a list of maps is
  # one step each, which is what a run that changed its mind looks like.
  defp run_believing(steps) when is_map(steps), do: run_believing([steps])

  defp run_believing(steps) do
    run_believing(steps, fn evidence -> %{"learning_module_0" => evidence} end)
  end

  # A run of a heterarchy: the same steps, but every module says its own thing
  # about each object, which is what a run of five modules actually records.
  defp run_believing(steps, by_module) do
    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: length(steps),
        config: %{}
      })

    run =
      steps
      |> Enum.with_index()
      |> Enum.reduce(run, fn {evidence, step}, run ->
        beliefs =
          evidence
          |> by_module.()
          |> Map.new(fn {module, objects} ->
            {module,
             %{"graphs" => Map.new(objects, fn {o, v} -> {o, %{"max_evidence" => v}} end)}}
          end)

        entry = %{
          "step" => step,
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "votes" => %{"sent" => 1, "used" => 1},
          "goals" => 1,
          "actions" => 1,
          "duration_us" => 120,
          "beliefs" => beliefs
        }

        {:ok, run} = RunHistory.record_step(run, entry, moment(step))
        run
      end)

    {:ok, run} = RunHistory.finish(run, %{"steps" => length(steps)})
    run
  end

  describe "the list of runs" do
    test "shows every run with how it ended", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#run-#{run.id}")
      assert render(view) =~ "tutorial/first_experiment"
      assert render(view) =~ "finished"
    end

    test "a run that has not started says queued, not running", %{conn: conn} do
      # A record is written the moment a run is queued, so its own status says
      # `running` before anything is running. The list says what is true.
      {:ok, queued} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert view |> element("#run-#{queued.id}") |> render() =~ "queued"
      refute view |> element("#run-#{queued.id}") |> render() =~ "running"
    end

    test "every heading sits over the value it names", %{conn: conn, run: run} do
      # A heading over the neighbouring column reads as a different fact: a
      # count headed "elapsed", a timestamp headed "ending". One heading per
      # cell is the whole guarantee, so it is counted rather than eyeballed.
      {:ok, view, _html} = live(conn, ~p"/runs")

      document = LazyHTML.from_fragment(render(view))

      assert Enum.count(LazyHTML.query(document, "thead th")) ==
               Enum.count(LazyHTML.query(LazyHTML.query(document, "#run-#{run.id}"), "td"))
    end

    test "says so when nothing has run", %{conn: conn} do
      # Empty is the state a fresh database is in, and it has to be a page.
      ExTbpMonty.Repo.delete_all(Monty.Studio.RunHistory.Run)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#runs")
    end
  end

  describe "narrowing the list" do
    test "a state pill filters the list, and the address carries it", %{conn: conn, run: run} do
      failed =
        insert_run(%{experiment: "base_config_10distinctobj_dist_agent", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#run-#{run.id}")
      assert has_element?(view, "#run-#{failed.id}")

      view |> element("#filter-failed") |> render_click()

      assert_patch(view, ~p"/runs?#{[state: "failed", q: ""]}")
      assert has_element?(view, "#run-#{failed.id}")
      refute has_element?(view, "#run-#{run.id}")
    end

    test "every word of the filter must match", %{conn: conn, run: run} do
      _base =
        insert_run(%{experiment: "base_config_10distinctobj_dist_agent", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      # One word narrows to the two names that carry it.
      view |> element("#run-search") |> render_change(%{"q" => "base"})
      assert_patch(view, ~p"/runs?#{[state: "all", q: "base"]}")
      refute has_element?(view, "#run-#{run.id}")

      # A second word narrows further: both have to appear, not either.
      view |> element("#run-search") |> render_change(%{"q" => "base dist"})
      assert_patch(view, ~p"/runs?#{[state: "all", q: "base dist"]}")

      view |> element("#run-search") |> render_change(%{"q" => "base nothing"})
      assert view |> render() =~ "No run matches"
    end

    test "the list is paged when there are more runs than a page", %{conn: conn} do
      for _ <- 1..26,
          do: insert_run(%{experiment: "tutorial/first_experiment", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      # The setup's own run makes twenty-seven.
      assert view |> element("#run-count") |> render() =~ "1–25 of 27"
      refute has_element?(view, "#page-previous")

      view |> element("#page-next") |> render_click()

      assert_patch(view, ~p"/runs?#{[state: "all", q: "", page: 2]}")
      assert view |> element("#run-count") |> render() =~ "26–27 of 27"
      assert view |> element("#page-number") |> render() =~ "page 2 of 2"
    end
  end

  describe "stopping a run from the list" do
    test "a run that is waiting can be stopped", %{conn: conn} do
      {:ok, queued} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#stop-#{queued.id}") |> render_click()

      assert render(view) =~ "Stopped: the run never started."
      assert RunHistory.get(queued.id).status == "failed"

      # Nothing is left to stop.
      refute has_element?(view, "#stop-#{queued.id}")
    end

    test "ending is offered only for a run that is going", %{conn: conn} do
      {:ok, queued} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#end-#{queued.id}")

      :ok = running(job)
      {:ok, _began} = RunHistory.mark_running(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#end-#{queued.id}")
    end

    test "a run that finished offers nothing to stop", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#stop-#{run.id}")
      refute has_element?(view, "#end-#{run.id}")
      assert has_element?(view, "#delete-#{run.id}")
    end
  end

  # A reader who lands on a queued run has three questions: how far along is
  # it, where do I watch it, and how do I stop it — and the page answers all
  # three, with Stop and Delete kept apart.
  describe "a run that is still going" do
    setup do
      {:ok, queued} =
        RunHistory.start(%{
          experiment: "tutorial/first_experiment",
          source: "monty",
          steps: 3,
          config: %{}
        })

      {:ok, job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      # A worker has it, which is what makes the record say `running` — and the
      # job is executing, because the worker's two words come together: a
      # `running` record beside a job nobody started is a pair nothing writes.
      :ok = running(job)
      {:ok, run} = RunHistory.mark_running(queued)

      {:ok, running: run}
    end

    test "says how far along it is, and that the steps land in the log", %{
      conn: conn,
      running: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#run-progress") |> render() =~ "step 0 / 3"
      assert view |> element("#run-waiting") |> render() =~ "appear here as the run goes"
    end

    test "links to the experiment page, which is where a run is started", %{
      conn: conn,
      running: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#open-experiment") |> render() =~
               ~s(href="#{~p"/experiments/#{run.experiment}"}")

      assert view |> element("#open-experiment") |> render() =~ "Open the experiment"
    end

    test "offers Stop, not Delete, while it is in flight", %{conn: conn, running: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#stop-#{run.id}")
      refute has_element?(view, "#delete-#{run.id}")
    end

    test "follows the worker: when it finishes, the page says so and Delete appears", %{
      conn: conn,
      running: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      {:ok, _closed} = RunHistory.finish(run, %{"steps" => 3})

      broadcast(run.id, {:finished, %{}})

      assert render(view) =~ "finished"
      assert has_element?(view, "#delete-#{run.id}")
      refute has_element?(view, "#stop-#{run.id}")
      refute has_element?(view, "#run-waiting")
    end

    test "a step the worker publishes lands on the page", %{conn: conn, running: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The step is written the way the worker writes it, so the page is
      # re-reading a record it would really meet.
      info = %{
        step: 0,
        duration_us: 1_000,
        percept_ids: ["patch"],
        inputs: %{"learning_module_0" => 1},
        votes: %{sent: 1, used: 1},
        goals: 1,
        actions: []
      }

      entry = Monty.Studio.RunLog.entry(info)
      moment = Monty.Studio.RunLog.moment(info, %{})
      {:ok, _written} = RunHistory.record_step(run, entry, moment)

      broadcast(run.id, {:step, %{line: "step 0", step: 0, frames: [], episode: 0, beliefs: %{}}})

      assert has_element?(view, "#log-0-0")
      assert view |> element("#run-progress") |> render() =~ "step 1 / 3"
    end

    # A window that only ever grows is the transcript again, reached a line at a
    # time instead of in one mount: a run watched for an hour ended with every
    # step it had taken still in the DOM, and the page stopped keeping up. What
    # the page follows is the tail — the oldest line leaves as the newest
    # arrives, and the page stays the size it was.
    test "keeps the log a window while following, so a long run does not grow it", %{
      conn: conn
    } do
      run = running_run(305)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      before = log_lines(render(view))
      oldest = List.first(before)
      assert oldest

      Enum.reduce(305..307, run, &record_step(&2, &1))

      broadcast(
        run.id,
        {:step, %{line: "step 307", step: 307, frames: [], episode: 0, beliefs: %{}}}
      )

      # The page answers a burst of steps once, on its own clock.
      send(view.pid, :refresh_due)

      now = log_lines(render(view))
      assert length(now) == length(before)
      refute oldest in now
      assert List.last(now) == "log-0-307"
    end

    test "asks again, so a run whose job died stops claiming to be running", %{
      conn: conn,
      running: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#run-status") |> render() =~ "running"

      # Nothing owns the run any more: the job was cancelled out from under it,
      # and the record has said nothing since. What stops the page saying
      # `running` is the record being closed, not a third word for a run that is
      # over.
      ExTbpMonty.Repo.update_all(
        from(j in Oban.Job, where: fragment("?->>'run_id' = ?", j.args, ^run.id)),
        set: [state: "cancelled"]
      )

      quiet_since(run, 61)
      send(view.pid, :show_poll)

      assert view |> element("#run-status") |> render() =~ "failed"
    end

    # A step is several messages — the line, the beliefs, the pictures — and each
    # announces the same step. A page that added a line per message showed the
    # same step four times, which is the page inventing steps the run did not
    # take.
    test "a second message about one step does not add a second step", %{
      conn: conn,
      running: run
    } do
      publish(run.id, 0)
      _ = :sys.get_state(Monty.Studio.RunStream)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-panel") |> render() =~ "steps 0–0"

      send(view.pid, {:studio, run.id, {:beliefs, %{}}})
      send(view.pid, :refresh_due)
      send(view.pid, {:studio, run.id, {:frames, []}})
      send(view.pid, :refresh_due)

      assert has_element?(view, "#log-0-0")
      assert length(log_lines(render(view))) == 1
      assert view |> element("#run-progress") |> render() =~ "step 1 / 3"
    end
  end

  describe "one run" do
    test "keeps its config snapshot, its inputs and its log", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-config")
      assert render(view) =~ "monty/learning_module"
      assert has_element?(view, "#log-0-0")
      assert has_element?(view, "#log-0-1")
    end

    # The snapshot is the run's whole config — a file, not a table — and the
    # facts above it are what a person comes to this page for. It is drawn
    # closed, and it is a `details`, so opening it is the browser's own doing and
    # a patch of the page leaves it however the reader left it.
    test "the whole config is a closed box until a reader opens it", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      snapshot = view |> element("#run-snapshot") |> render()

      assert snapshot =~ "<details"
      refute snapshot =~ ~r/<details[^>]*\sopen/
      assert snapshot =~ "Config snapshot"
      assert has_element?(view, "#run-config")
    end

    # What the run was started with, read back from its own record: the same
    # sentences the experiment page promises before a run, so that what was
    # promised and what was done are the same words — and the seed the record
    # kept, not the one the config names.
    test "shows the configuration the record kept, not the experiment's today", %{conn: conn} do
      {:ok, config} = Monty.Config.Composer.compose("base_config_10distinctobj_dist_agent")

      {:ok, run} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 400,
          seed: 7,
          config: config
        })

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      facts = view |> element("#run-configuration") |> render()

      assert facts =~ "episodes, as the config runs them"
      assert facts =~ "140 eval"
      assert facts =~ "training · evaluation"
      assert facts =~ "train no · eval yes"
      assert facts =~ ~r{seed</dt>\s*<dd[^>]*>7</dd>}
    end

    # A step's clock is the reader's, and only the browser knows their zone. So
    # the page has to hand it the instant and let the hook rewrite the words;
    # printing the server's own clock would show a container's UTC to someone
    # sitting in Berlin.
    test "a step's clock reaches the browser as an instant, not as the server's text", %{
      conn: conn,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-log[phx-hook='ExTbpMontyWeb.LocalTime.LocalTime']")
      assert has_element?(view, "#log-0-0 time[data-local-time='clock'][datetime]")
    end

    # The tooltip is drawn by a hook, but the words and numbers in it come from
    # the server — so the fixture is the page: one sample per step, each with
    # the object it belongs to, the step, and what that step was worth.
    test "the chart carries a labelled sample for what the pointer would show", %{
      conn: conn,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      decoded = samples(view)

      # The hover is read at the pointer's own place, which is a step between two
      # of these, so what is carried is what the sentence is made of — the object,
      # the step, the value, the unit — rather than a sentence about one of them.
      assert decoded != []
      assert Enum.all?(decoded, &is_binary(&1["line"]))
      assert Enum.all?(decoded, &is_number(&1["step"]))
      assert Enum.all?(decoded, &is_number(&1["value"]))
      assert Enum.all?(decoded, &Map.has_key?(&1, "unit"))
    end

    test "says which episode it is", %{conn: conn} do
      # After a parallel start the name alone does not say which row this is.
      {:ok, run} =
        RunHistory.start(%{
          experiment: "base_10simobj_surf_agent",
          source: "monty",
          steps: 0,
          episode: 3,
          config: %{}
        })

      {:ok, run} = RunHistory.finish(run, %{})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#run-episode") |> render() =~ "episode 3"
    end

    test "a run id that does not exist is a page, not a crash", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/runs/00000000-0000-4000-8000-000000000000")

      assert html =~ "gone"
    end

    test "an address that is not a run id at all is that same page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/runs/not-a-run")

      assert html =~ "gone"
    end

    test "offers the files the run wrote, with their sizes", %{conn: conn, run: run} do
      Monty.Test.Tmp.env_dir("studio-runs", :studio_artifacts_dir)
      :ok = Monty.Studio.Artifacts.start(run.id)

      File.write!(
        Path.join(Monty.Studio.Artifacts.dir(run.id), "eval_stats.csv"),
        "episode,performance\n"
      )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-file-eval_stats-csv")
      assert has_element?(view, "a[href='/runs/#{run.id}/files/eval_stats.csv']")
    end

    test "says so when a run wrote nothing", %{conn: conn, run: run} do
      # A run whose config asks for a logger this port does not have writes no
      # files at all, and the page says where to look rather than staying silent.
      Monty.Test.Tmp.env_dir("studio-runs", :studio_artifacts_dir)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-files-empty")
    end
  end

  describe "a run that is one part of a batch" do
    # A parallel run is several runs (Monty.Studio.Partition), and a page about one
    # of them used to say nothing about the others: they ran, and nobody saw them
    # until the list. One card each, one after the other — the pyview dashboard's
    # multi-publisher view.
    test "shows every part's card, not only its own", %{conn: conn} do
      # One run asked for two parts: the parts are its plan, and each part's steps
      # are the stream that plan named. What the run page draws is both cards, one
      # after the other — a page that showed only the part it was opened on hid the
      # other while it ran.
      parts =
        for index <- 0..1 do
          %{
            "index" => index,
            "of" => 2,
            "phase" => "eval",
            "stream" => Ecto.UUID.generate(),
            "phases" => %{"eval" => [index]}
          }
        end

      {:ok, run} =
        RunHistory.start(%{
          experiment: "tutorial/first_experiment",
          source: "monty",
          steps: 2,
          episode: 0,
          inputs: %{"parallel" => 2, "parts" => parts}
        })

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-parts")

      for {part, index} <- Enum.with_index(parts) do
        assert view |> element("#part-#{part["stream"]}") |> render() =~ "part #{index + 1} of 2"
      end
    end

    test "a run of the whole experiment has no cards, because it has one part", %{conn: conn} do
      {:ok, run} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#run-parts")
    end
  end

  describe "a run that did not finish" do
    test "says what stopped it, above everything else", %{conn: conn, run: run} do
      {:ok, failed} =
        RunHistory.finish(run, %{"reason" => "the world would not start"}, "failed")

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert view |> element("#run-failure") |> render() =~ "the world would not start"
    end

    test "a run whose process is gone is closed when its page is opened", %{conn: conn} do
      # The row a restart leaves behind: `running`, with no job, no process, and
      # nothing written to it for longer than the grace a fresh record gets.
      # Opening the page is the first thing that could notice, so it notices.
      {:ok, abandoned} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      quiet_since(abandoned, 61)

      {:ok, view, _html} = live(conn, ~p"/runs/#{abandoned.id}")

      # The check runs beside the page rather than in front of it, and the page
      # reads its answer when it is next drawn — which is what opening the page
      # is. So the closing has happened by the time the page says what happened.

      assert view |> element("#run-failure") |> render() =~ "stopped before it finished"
      assert RunHistory.get(abandoned.id).status == "failed"

      # Nothing about a killed process is a missing file, so the page does not
      # send the reader to the prerequisites for it.
      refute has_element?(view, "#run-failure-prerequisites")
    end

    test "a run stopped by a memory that is not here points at where it is fetched", %{
      conn: conn,
      run: run
    } do
      {:ok, failed} =
        RunHistory.finish(
          run,
          %{
            "reason" =>
              "No memory this application can read for pretrained_ycb_v14, and a run " <>
                "without one cannot recognise any object. Fetch it at /prerequisites."
          },
          "failed"
        )

      {:ok, view, _html} = live(conn, ~p'/runs/#{failed.id}')

      assert has_element?(view, "#run-failure-prerequisites")
    end

    test "a crash is said in a sentence, with the trace folded away", %{conn: conn, run: run} do
      crash = """
      ** (ArgumentError) Monty.Frameworks.Actions.SetAgentPose sets a pose outright, which the stand-in world does not do; use a simulator behind Monty.Simulators.Port.Environment instead
          (ex_tbp_monty 0.1.0) lib/monty/simulators/synthetic/kinematics.ex:118: Monty.Simulators.Synthetic.Kinematics.act/2
          (elixir 1.20.4) lib/enum.ex:2622: Enum."-reduce/3-lists^foldl/2-0-"/3
      """

      {:ok, failed} = RunHistory.finish(run, %{"reason" => crash}, "failed")

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert view |> element("#run-failure-what") |> render() =~
               "cannot be posed directly"

      assert has_element?(view, "#run-failure-hint")

      # The trace is there for whoever wants it, and costs nobody else a glance.
      assert has_element?(view, "#run-failure-technical pre")
      refute has_element?(view, "details#run-failure-technical[open]")
    end

    # A process that was killed leaves the queue's own words in the record, and
    # those words are `** (EXIT from #PID<…>)` — not something to hand a reader.
    test "a killed process is said in a sentence, not by its pid", %{conn: conn, run: run} do
      {:ok, failed} =
        RunHistory.finish(run, %{"reason" => "** (EXIT from #PID<0.5994.0>) killed"}, "failed")

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert view |> element("#run-failure-what") |> render() =~
               "process was killed"

      refute view |> element("#run-failure-what") |> render() =~ "**"

      assert view |> element("#run-failure-technical pre") |> render() =~ "** (EXIT from"
    end

    test "a record that keeps its traceback apart shows the sentence over it", %{
      conn: conn,
      run: run
    } do
      {:ok, failed} =
        RunHistory.finish(
          run,
          %{"reason" => "The run could not start.", "technical" => "** (exit) :killed"},
          "failed"
        )

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert view |> element("#run-failure-what") |> render() =~ "The run could not start."
      assert view |> element("#run-failure-technical pre") |> render() =~ "** (exit)"
    end

    test "how it ended is said once, not again in the summary", %{conn: conn, run: run} do
      {:ok, failed} =
        RunHistory.finish(
          run,
          %{"reason" => "the world would not start", "steps" => 3},
          "failed"
        )

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      said = view |> render() |> String.split("the world would not start") |> length()

      assert said == 2
    end

    test "a run that finished says nothing about how it ended", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#run-failure")
    end
  end

  describe "replaying a run" do
    test "opens at the last step, with the picture that step saw", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The slider is held by a hook while it is dragged: a patch that lands
      # mid-drag would otherwise put the handle back where the server left it.
      assert view |> element("#replay-slider") |> render() =~
               ~s(phx-hook="ExTbpMontyWeb.StudioComponents.ReplaySlider")

      # The hover's readout is drawn by the hook, in a box the page marks to be
      # left alone: the picture is patched on every step, and a readout written
      # into it would be a readout the next patch takes away.
      assert has_element?(view, ~s(#replay-chart-readout[phx-update="ignore"]))

      assert has_element?(view, "#replay-panel")
      assert has_element?(view, "#replay-slider")
      assert has_element?(view, "#replay-frame-patch")
      assert view |> element("#replay-step") |> render() =~ "step 1"
      assert view |> element("#replay-frame-patch") |> render() =~ "step 1"
    end

    test "moving the slider shows that step, from the record", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-seek") |> render_change(%{"step" => "0"})

      assert view |> element("#replay-step") |> render() =~ "step 0"

      # Step 0 saw the surface 2 cm away, step 1 further back: the frame says
      # which, in the same words the run's own log used.
      assert view |> element("#replay-frame-patch") |> render() =~ "depth 0.020–0.040 m"

      view |> element("#replay-seek") |> render_change(%{"step" => "1"})

      assert view |> element("#replay-frame-patch") |> render() =~ "depth 0.030–0.050 m"
    end

    # A run that is still stepping moves on without the page. Reading the record
    # again answers the step the page already had, so a replay that kept it was a
    # picture of the moment the page was opened however long the run went on —
    # the chart stopped following the evidence while the run kept producing it.
    test "keeps up with a run that is still stepping", %{conn: conn} do
      run = running_run(2)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-step") |> render() =~ "step 1"
      assert view |> element("#replay-panel") |> render() =~ "steps 0–1"

      run = record_step(run, 2)
      send(view.pid, {:studio, run.id, {:step, %{step: 2}}})
      send(view.pid, :refresh_due)

      assert view |> element("#replay-step") |> render() =~ "step 2"
      assert view |> element("#replay-panel") |> render() =~ "steps 0–2"
    end

    # The other half of the same rule: a step the reader chose is theirs. A
    # refresh that pulled the playhead forward would take away the step they
    # were looking at, every time the run stepped.
    test "a step the reader chose stays put while the run steps on", %{conn: conn} do
      run = running_run(2)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-seek") |> render_change(%{"step" => "0"})

      run = record_step(run, 2)
      send(view.pid, {:studio, run.id, {:step, %{step: 2}}})
      send(view.pid, :refresh_due)

      assert view |> element("#replay-step") |> render() =~ "step 0"
      assert view |> element("#replay-panel") |> render() =~ "steps 0–2"
    end

    # Monty's dashboard has this control, and it is the question a page watching
    # a run has to answer: is the chart about the newest step, or about the one
    # being read? Taking the playhead anywhere turns it off; ticking it comes
    # back to the newest step.
    test "follow latest steps is a choice, and comes back to the newest step", %{conn: conn} do
      run = running_run(3)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-follow[checked]")
      view |> element("#replay-seek") |> render_change(%{"step" => "0"})
      refute has_element?(view, "#replay-follow[checked]")

      view |> element("#replay-follow") |> render_click()

      assert has_element?(view, "#replay-follow[checked]")
      assert view |> element("#replay-step") |> render() =~ "step 2"
    end

    test "the chart follows the step and can be zoomed", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-chart polyline")

      view |> element("#replay-zoom-in") |> render_click()
      assert has_element?(view, "#replay-chart")

      view |> element("#replay-zoom-all") |> render_click()

      # "all" is the whole run, so the window is labelled with both ends.
      assert view |> element("#replay-panel") |> render() =~ "steps 0–1"
    end

    # A run of two episodes counts its steps from zero twice, so the step a
    # recorded moment carries cannot address it. The slider is the run's own
    # sequence, one position per recorded step.
    test "the slider runs over recorded positions", %{conn: conn} do
      run = run_believing([%{"mug" => 1.0}, %{"mug" => 2.0}, %{"mug" => 3.0}])
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      slider = view |> element("#replay-slider") |> render()

      assert slider =~ ~s{min="0"}
      assert slider =~ ~s{max="2"}

      # The window is the chart's axis; zooming it leaves the slider alone.
      view |> element("#replay-zoom-in") |> render_click()

      assert view |> element("#replay-slider") |> render() =~ ~s{max="2"}
    end

    test "a drag across the chart zooms to the range it drew", %{conn: conn} do
      run = run_believing([%{"mug" => 1.0}, %{"mug" => 2.0}, %{"mug" => 3.0}])
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> render_hook("replay_brush", %{"from" => "1", "to" => "2"})

      assert view |> element("#replay-panel") |> render() =~ "steps 1–2"
    end

    test "the value axis is labelled beside the plot, on numbers a reader can subtract", %{
      conn: conn
    } do
      run = run_believing([%{"mug" => 1.0}, %{"mug" => 5.0}])
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      axis = view |> element("#replay-chart-y-axis") |> render()

      # Cutting the range into equal parts labelled a 1..5 axis 1.0, 2.3, 3.7,
      # 5.0 — four numbers nobody compares in their head. Whole steps are the
      # ladder a reader already has, and the ladder starts at zero: evidence is
      # measured from there.
      assert axis_labels(axis) == ["0", "2", "4"]

      # The labels are beside the plot, not in it: text inside an SVG stretched
      # by `preserveAspectRatio="none"` is drawn wider than it is tall.
      plot = view |> element("#replay-chart") |> render()
      refute plot =~ "<text"
    end

    test "the axis names zero when the evidence went under it", %{conn: conn} do
      run = run_believing([%{"mug" => 8.7}, %{"mug" => -6.4}])
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      axis = view |> element("#replay-chart-y-axis") |> render()

      # Evidence is measured from zero, so an axis that spans it has to say
      # where it is: the range cut into quarters put 0 between two labels and
      # named neither of them zero.
      assert axis_labels(axis) == ["-5", "0", "5"]
    end

    test "opens on every object, whatever the run before it was left on", %{conn: conn} do
      # All ten objects on one axis with a legend is how an episode is read, and
      # how Monty's own dashboard draws it. Choosing a run is a patch, which
      # keeps this process alive: a series picked for one run used to follow the
      # reader to the next one, so every run after the first opened on one line,
      # with no legend and nothing saying why.
      steps = [
        %{"mug" => 1.0, "bowl" => 0.5},
        %{"mug" => 2.0, "bowl" => 1.0},
        %{"mug" => 3.0, "bowl" => 0.2}
      ]

      first = run_believing(steps)
      second = run_believing(steps)

      {:ok, view, _html} = live(conn, ~p"/runs/#{first.id}")

      assert has_element?(view, "#replay-chart-legend")
      assert has_element?(view, "#replay-series option[value='objects'][selected]")

      view |> element("#replay-series") |> render_change(%{"series" => "evidence"})

      assert has_element?(view, "#replay-series option[value='evidence'][selected]")
      refute has_element?(view, "#replay-chart-legend")

      view |> render_patch(~p"/runs/#{second.id}")

      assert has_element?(view, "#replay-series option[value='objects'][selected]")
      assert has_element?(view, "#replay-chart-legend")
    end

    test "a chart can show another series", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-series") |> render_change(%{"series" => "votes_used"})

      # Votes are counts, not metres.
      assert has_element?(view, "#replay-chart")
      refute view |> element("#replay-chart") |> render() =~ " m"
    end

    test "hovering the line names the step and the value it was", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # Every step the run recorded is there to be read, in the run's own order.
      assert Enum.any?(samples(view), &(&1["step"] == 1))
    end

    test "a chart that has changed answers the pointer with its own words", %{
      conn: conn,
      run: run
    } do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> samples() |> Enum.map(& &1["unit"]) |> Enum.uniq() == [""]

      # The page keeps a chart's samples beside the chart it made them from, so
      # a chart that has changed must not still be read out in the old one's
      # units.
      view |> element("#replay-series") |> render_change(%{"series" => "duration_us"})

      assert view |> samples() |> Enum.map(& &1["unit"]) |> Enum.uniq() == ["µs"]
    end

    test "and the value axis is named in that series' own units", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-series") |> render_change(%{"series" => "duration_us"})
      assert view |> element("#replay-chart-y-name") |> render() =~ "microseconds"

      # A count is not a duration and evidence is neither: one axis name for all
      # of them would have to be wrong about two.
      view |> element("#replay-series") |> render_change(%{"series" => "votes_used"})
      assert view |> element("#replay-chart-y-name") |> render() =~ "votes"

      view |> element("#replay-series") |> render_change(%{"series" => "evidence"})
      assert view |> element("#replay-chart-y-name") |> render() =~ "evidence"
    end

    test "a run that built graphs opens on every object at once", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0, "bowl" => 4.0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The picker offers it, and it is where the page opened.
      assert has_element?(view, "#replay-series option[value='objects'][selected]")

      # One line per object, each with its own colour. A line is cut wherever an
      # episode ends, so the element is named by its line and its stretch.
      assert has_element?(view, "#replay-line-0-0")
      assert has_element?(view, "#replay-line-1-0")

      # Named, because a colour nobody can name is a puzzle.
      legend = view |> element("#replay-chart-legend") |> render()
      assert legend =~ "bowl"
      assert legend =~ "mug"

      # And one number says what the episode came to.
      assert view |> element("#replay-best") |> render() =~ "bowl"
    end

    test "a hover over those lines names the object it is on", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0, "bowl" => 4.0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert Enum.any?(samples(view), &(&1["line"] == "bowl" and &1["step"] == 0))
    end

    test "the two strongest theories change as the slider moves", %{conn: conn} do
      run = run_believing([%{"mug" => 1.0, "bowl" => 4.0}, %{"mug" => 9.0, "bowl" => 2.0}])

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The page opens where the run ended: mug is the guess by then.
      assert view |> element("#replay-theories") |> render() =~ "mug"
      assert view |> element("#replay-theories") |> render() =~ "9.00"

      view |> element("#replay-seek") |> render_change(%{"step" => "0"})

      theories = view |> element("#replay-theories") |> render()
      assert theories =~ "bowl"
      assert theories =~ "4.00"
    end

    test "a step that weighed nothing says nothing", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#replay-theories")
    end

    test "a run with nothing to compare gets one line and no legend", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-line-0-0")
      refute has_element?(view, "#replay-line-1-0")
      refute has_element?(view, "#replay-chart-legend")
      refute has_element?(view, "#replay-best")
    end

    test "a run that kept no graphs says why its evidence line is flat", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      note = view |> element("#replay-chart-no-graphs") |> render()

      assert note =~ "nothing to compare here"
      assert note =~ "builds graphs instead of matching them"
    end

    test "a run with graphs does not need the explanation", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#replay-chart-no-graphs")
    end

    test "playing walks the steps forward on its own", %{conn: conn} do
      # Three steps, because two ticks are the point: a run of two would have
      # stopped at its own end and proved nothing.
      run = run_believing([%{"mug" => 1.0}, %{"mug" => 2.0}, %{"mug" => 3.0}])

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # Playing from the end starts again at the beginning, which is what a
      # person who pressed play wanted.
      view |> element("#replay-play") |> render_click()
      assert view |> element("#replay-step") |> render() =~ "step 0"

      # The replay's clock, wound by hand: two ticks are two steps, which a
      # redraw that quietly switches playback off would not be.
      send(view.pid, :replay_tick)
      send(view.pid, :replay_tick)
      assert view |> element("#replay-step") |> render() =~ "step 2"
    end

    test "a run with no steps says so instead of showing an empty slider", %{conn: conn} do
      {:ok, empty} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{empty.id}")

      assert has_element?(view, "#replay-empty")
      refute has_element?(view, "#replay-slider")
    end

    # Five modules of one heterarchy are five opinions about the same objects,
    # and the first chart is the strongest of them — which is the right answer
    # for the ensemble and the wrong one for "did they agree?". A run whose
    # ensemble recognised the object while four of its modules timed out is
    # exactly what the one chart cannot say.
    test "offers a chart a learning module, beside the one of every object", %{conn: conn} do
      run =
        run_believing([%{"mug" => 1.0, "bowl" => 0.5}], fn evidence ->
          %{
            "learning_module_0" => evidence,
            "learning_module_1" => %{"bowl" => 0.1}
          }
        end)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      picker = view |> element("#replay-series") |> render()

      assert picker =~ "every object (2)"
      assert picker =~ "objects · learning_module_0"
      assert picker =~ "objects · learning_module_1"
    end

    test "and a module's chart is drawn from that module's own evidence", %{conn: conn} do
      run =
        run_believing([%{"mug" => 1.0}, %{"mug" => 2.0}], fn _evidence ->
          %{
            "learning_module_0" => %{"mug" => 1.0},
            "learning_module_1" => %{"mug" => 7.0}
          }
        end)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The ensemble's line is the strongest module's, so it is the 7.0 one.
      assert Enum.map(samples(view), & &1["value"]) == [7.0, 7.0]

      view
      |> element("#replay-series")
      |> render_change(%{"series" => "module:learning_module_0"})

      assert Enum.map(samples(view), & &1["value"]) == [1.0, 1.0]
    end

    # A picker is not where a reader looks to find out what the chart they are
    # looking at is — and with six object charts there is a real question to
    # answer about the figure rather than in a dropdown. It is captioned under
    # it, the way a figure is, and each axis carries its own name.
    test "and the chart is captioned under the figure, both axes named", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0, "bowl" => 0.4})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-chart-title") |> render() =~
               "Evidence for every object — strongest module"

      assert view |> element("#replay-chart-y-name") |> render() =~ "evidence"
      assert view |> element("#replay-chart-x-name") |> render() =~ "step"

      # Under the figure, not above it: the caption follows the legend in the
      # page's own order, so a reader meets the picture first.
      html = render(view)

      assert [plot, legend, caption] =
               order_in_page(html, ["replay-chart", "replay-chart-legend", "replay-chart-title"])

      assert plot < legend and legend < caption

      view
      |> element("#replay-series")
      |> render_change(%{"series" => "module:learning_module_0"})

      # The title follows the chart: a line drawn from one module's beliefs is a
      # different claim about the same objects.
      assert view |> element("#replay-chart-title") |> render() =~
               "Evidence for every object — as learning_module_0 held it"
    end
  end

  describe "deleting a run" do
    test "asks before it deletes anything", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#confirm-delete")

      view |> element("#delete-#{run.id}") |> render_click()

      assert has_element?(view, "#confirm-delete")
      assert RunHistory.get(run.id) != nil
    end

    test "keeping it leaves the record alone", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#delete-#{run.id}") |> render_click()
      view |> element("#cancel-delete") |> render_click()

      refute has_element?(view, "#confirm-delete")
      assert RunHistory.get(run.id) != nil
    end

    test "confirming deletes it", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#delete-#{run.id}") |> render_click()
      view |> element("#confirm-delete-button") |> render_click()

      assert RunHistory.get(run.id) == nil
      refute has_element?(view, "#run-#{run.id}")
    end
  end

  describe "deleting many runs" do
    test "one filter and one confirmation delete every run it matches", %{conn: conn, run: run} do
      first = insert_run(%{experiment: "base_a", status: "failed"})
      second = insert_run(%{experiment: "base_b", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs?#{[state: "failed", q: ""]}")

      # The button says what the click does: every run the filter matches, not
      # the page of them on screen.
      assert view |> element("#delete-matching") |> render() =~ "Delete all 2 matching"

      view |> element("#delete-matching") |> render_click()

      dialog = view |> element("#confirm-bulk-delete") |> render()
      assert dialog =~ "Delete every run this filter matches?"
      assert dialog =~ "2 run(s)"

      # The rows go in a task, so the page is answered twice: once when the
      # deletion starts, once when it is over. Only the second is a state this
      # test can wait for — the first is gone the moment a fast delete finishes.
      view |> element("#confirm-bulk-delete-button") |> render_click()

      assert render_async(view) =~ "Deleted 2 runs."

      assert RunHistory.get(first.id) == nil
      assert RunHistory.get(second.id) == nil

      # The runs that were not shown are still there, and so is the filter.
      assert RunHistory.get(run.id) != nil
      assert render(view) =~ "No run matches"
    end

    test "keeping them leaves every one of them alone", %{conn: conn} do
      failed = insert_run(%{experiment: "base_a", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs?#{[state: "failed", q: ""]}")

      view |> element("#delete-matching") |> render_click()
      view |> element("#cancel-bulk-delete") |> render_click()

      refute has_element?(view, "#confirm-bulk-delete")
      assert RunHistory.get(failed.id) != nil
    end

    # Clearing a machine of finished work is a statement about the machine, not
    # about the filter a person happens to be looking at — so this one counts and
    # deletes every run that is done, whatever the pills say, and leaves the one
    # in flight alone.
    test "purging done runs ignores the filter and keeps what is running", %{conn: conn} do
      finished = insert_run(%{experiment: "base_a", status: "finished"})
      stopped = insert_run(%{experiment: "base_b", status: "stopped"})
      running = insert_run(%{experiment: "base_c", status: "running"})
      failed = insert_run(%{experiment: "base_d", status: "failed"})

      done_before =
        RunHistory.ids_matching(state: "finished") ++ RunHistory.ids_matching(state: "stopped")

      {:ok, view, _html} = live(conn, ~p"/runs?#{[state: "failed", q: ""]}")

      assert view |> element("#purge-done") |> render() =~ "Purge #{length(done_before)} done"

      view |> element("#purge-done") |> render_click()

      assert view |> element("#confirm-bulk-delete") |> render() =~
               "Delete every finished and stopped run?"

      view |> element("#confirm-bulk-delete-button") |> render_click()

      assert render_async(view) =~ "Deleted #{length(done_before)} runs."

      for id <- done_before, do: assert(RunHistory.get(id) == nil)

      assert RunHistory.get(finished.id) == nil
      assert RunHistory.get(stopped.id) == nil
      assert RunHistory.get(running.id) != nil
      assert RunHistory.get(failed.id) != nil
    end

    test "picking rows deletes just the rows picked", %{conn: conn, run: run} do
      first = insert_run(%{experiment: "base_a", status: "failed"})
      second = insert_run(%{experiment: "base_b", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#delete-selected")

      view |> element("#pick-#{first.id}") |> render_click()
      view |> element("#pick-#{second.id}") |> render_click()

      assert view |> element("#selected-count") |> render() =~ "2 selected"

      view |> element("#delete-selected") |> render_click()

      assert view |> element("#confirm-bulk-delete") |> render() =~ "Delete the selected runs?"

      view |> element("#confirm-bulk-delete-button") |> render_click()

      assert RunHistory.get(first.id) == nil
      assert RunHistory.get(second.id) == nil
      assert RunHistory.get(run.id) != nil

      # Nothing is left picked, so the question cannot be asked twice.
      refute has_element?(view, "#selected-count")
      refute has_element?(view, "#confirm-bulk-delete")
    end

    test "picking all takes the page, and clearing lets it go again", %{conn: conn, run: run} do
      other = insert_run(%{experiment: "base_a", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#pick-all") |> render_click()

      assert view |> element("#selected-count") |> render() =~ "2 selected"

      view |> element("#clear-selection") |> render_click()

      refute has_element?(view, "#selected-count")
      assert RunHistory.get(run.id) != nil
      assert RunHistory.get(other.id) != nil
    end

    # The rows are a stream: a tick drawn from the selection only moves when the
    # rows are sent again, so "2 selected" in the toolbar said nothing about the
    # boxes — and Clear left the tick standing. These two assertions are the ones
    # the toolbar count could not make.
    test "a picked row shows its tick, and clearing takes it back", %{conn: conn} do
      picked = insert_run(%{experiment: "base_ticked", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#pick-#{picked.id}[aria-pressed=false]")

      view |> element("#pick-#{picked.id}") |> render_click()

      assert has_element?(view, "#pick-#{picked.id}[aria-pressed=true]")

      view |> element("#clear-selection") |> render_click()

      assert has_element?(view, "#pick-#{picked.id}[aria-pressed=false]")
    end

    test "select all picks every row on the page and says how many", %{conn: conn} do
      insert_run(%{experiment: "base_one", status: "failed"})
      insert_run(%{experiment: "base_two", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs?state=failed")

      assert view |> element("#select-all") |> render() =~ "Select all"

      view |> element("#select-all") |> render_click()

      assert view |> element("#selected-count") |> render() =~ "selected"
      assert has_element?(view, "#pick-all[aria-pressed=true]")

      # Every row on the page carries the tick, not only the toolbar its count.
      for row <- RunHistory.search(state: "failed").runs do
        assert has_element?(view, "#pick-#{row.id}[aria-pressed=true]"),
               "row #{row.experiment} was not drawn as picked"
      end

      # Nothing left to select, so the sentence is not offered again.
      refute has_element?(view, "#select-all")
    end
  end
end
