defmodule Monty.Studio.RunStreamTest do
  @moduledoc """
  What a step hands over, and what becomes of it.

  A worker's step publishes a *report* — what the coordinator reported, what each
  module believed, what the sensors saw, and the moment it happened — and this
  process makes the record's entry, the log's line and the page's announcement
  out of it. These tests pin that division: a report is enough, and the moment
  that travels with it is the moment the step was taken, not the moment it was
  written.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.{Artifacts, RunLog, RunStream}
  alias Monty.Studio.RunStream.Pictures

  # A moment far enough from now that a line carrying it cannot be mistaken for
  # one carrying the clock of the process that wrote it.
  @moment "2026-11-09T22:41:27.137962Z"

  setup do
    run_id = Ecto.UUID.generate()
    :ok = Artifacts.start(run_id)
    on_exit(fn -> Artifacts.forget(run_id) end)

    %{run_id: run_id}
  end

  describe "a step's report" do
    test "becomes a step of the record, with the moment it was taken", %{run_id: run_id} do
      beliefs = %{"learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 5.0}}}}

      RunStream.publish(
        run_id,
        report(step: 7, episode: 3, beliefs: beliefs, at: @moment)
      )

      assert {[entry], [_moment]} = RunStream.steps(run_id)

      assert entry["step"] == 7
      assert entry["episode"] == 3
      assert entry["at"] == @moment
      assert entry["beliefs"]["learning_module_0"]["graphs"]["mug"]["max_evidence"] == 5.0
    end

    test "is enough for the line the log and the page are given", %{run_id: run_id} do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Studio.Jobs.Run.topic(run_id))

      RunStream.publish(run_id, report(step: 7, at: @moment))

      # Five seconds, not the default tenth of one: the announcement comes from
      # the stream's own process, and a suite running sixteen cases at a time can
      # keep that process waiting. The wait is the answer arriving, not a sleep.
      assert_receive {:studio, ^run_id, {:step, announcement}}, 5_000

      clock = RunLog.at(%{"at" => @moment}).clock

      assert announcement.step == 7
      assert String.starts_with?(announcement.line, clock)
      assert announcement.line =~ "step 7"
    end

    test "writes the line to the run's own log file", %{run_id: run_id} do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Studio.Jobs.Run.topic(run_id))

      RunStream.publish(run_id, report(step: 1, at: @moment))

      # The broadcast follows the write, so a step the page has heard of is a
      # step the file has too.
      assert_receive {:studio, ^run_id, {:step, _announcement}}, 5_000

      assert File.read!(Artifacts.log_path(run_id)) =~ "step 1"
    end
  end

  # What a page reads, and what a boundary writes, both come from this table:
  # `steps_from/2` asks the process only for the order and then reads here, and
  # `read_from/2` is that read. The keys are ordinary table keys, so the mistake
  # that is easy to make and invisible until two runs are open at once is reading
  # on past the end of one run and into the next.
  describe "the steps a page reads" do
    test "are the ones after the position it already has", %{run_id: run_id} do
      for step <- 1..4, do: RunStream.publish(run_id, report(step: step))
      settled(run_id)

      {entries, moments} = RunStream.read_from(run_id, 1)

      assert Enum.map(entries, & &1["step"]) == [3, 4]
      assert length(moments) == 2
    end

    test "stop at the end of the run they belong to", %{run_id: run_id} do
      other = Ecto.UUID.generate()
      :ok = Artifacts.start(other)
      on_exit(fn -> Artifacts.forget(other) end)

      RunStream.publish(run_id, report(step: 1))
      RunStream.publish(other, report(step: 1))
      RunStream.publish(run_id, report(step: 2))
      settled(run_id)

      {entries, _moments} = RunStream.read_from(run_id, -1)

      assert Enum.map(entries, & &1["step"]) == [1, 2]
    end

    test "are read whole when the page asks for everything", %{run_id: run_id} do
      for step <- 1..3, do: RunStream.publish(run_id, report(step: step))
      settled(run_id)

      assert {entries, moments} = RunStream.steps_from(run_id, -1)
      assert Enum.map(entries, & &1["step"]) == [1, 2, 3]
      assert length(moments) == 3
    end

    test "are none, for a run this node never stepped", %{run_id: run_id} do
      settled(run_id)

      assert RunStream.read_from(Ecto.UUID.generate(), -1) == {[], []}
    end

    test "are none once the run's record holds them", %{run_id: run_id} do
      RunStream.publish(run_id, report(step: 1))
      settled(run_id)

      :ok = RunStream.clear(run_id)

      assert RunStream.read_from(run_id, -1) == {[], []}
      assert RunStream.count(run_id) == 0
    end

    # A page repairing a transcript wants the lines and the beliefs, not the
    # pictures and the sensor numbers beside them: a moment is eleven kilobytes
    # a step, and the page threw every one of them away.
    test "are the same steps without the moments beside them", %{run_id: run_id} do
      for step <- 1..4, do: RunStream.publish(run_id, report(step: step))
      settled(run_id)

      {tail, _moments} = RunStream.read_from(run_id, 1)
      {whole, _moments} = RunStream.read_from(run_id, -1)

      assert RunStream.entries_from(run_id, 1) == tail
      assert RunStream.entries_from(run_id, -1) == whole
    end

    test "are none past the end, and none for a run this node never stepped", %{run_id: run_id} do
      RunStream.publish(run_id, report(step: 1))
      settled(run_id)

      assert RunStream.entries_from(run_id, 0) == []
      assert RunStream.entries_from(Ecto.UUID.generate(), -1) == []
    end
  end

  # Everything the test process has handed over, so far, has landed: a call
  # answers after the casts that came before it.
  defp settled(run_id), do: RunStream.count(run_id)

  # A step whose sensor saw something: one depth array, which is what a picture
  # is drawn from, and the sensor a page is told to draw.
  defp seeing(options) do
    report(
      step: Keyword.get(options, :step, 1),
      episode: Keyword.get(options, :episode, 0),
      observations: %{
        "agent_id_0" => %{
          "patch" => %{"depth" => Keyword.fetch!(options, :depth), "location" => [0.0, 0.0, 0.1]}
        }
      },
      sensor_ids: ["patch"]
    )
  end

  # The same step once the stream has made the record's entry and the log's line
  # of it: what `Pictures` is handed, and what it reads the step's own number from.
  defp step(options) do
    report = seeing(options)
    Map.merge(report, %{number: report.info.step, line: "step #{report.info.step}", entry: %{}})
  end

  describe "a step's pictures" do
    # Drawing them is 1.2–1.7 ms of PNG and 0.8–1.0 ms of writing, per sensor per
    # step, and a boundary asks this process for everything it has been handed. So
    # the record keeps where a picture will be, and the drawing happens behind it:
    # a queue of undrawn steps is not something a boundary waits for.
    test "are named by the record, whether or not they have been drawn", %{run_id: run_id} do
      RunStream.publish(run_id, seeing(depth: [[0.05, 0.07], [0.05, 0.07]]))

      assert {[entry], [moment]} = RunStream.steps(run_id)
      assert entry["step"] == 1

      assert %{"patch" => %{"images" => pictures}} = moment["sensors"]
      assert pictures["depth"] == "/runs/#{run_id}/frames/0/patch-depth.png"
      assert pictures["range"] == [0.05, 0.07]
    end

    test "keep their own place when the next episode numbers its steps from nought again", %{
      run_id: run_id
    } do
      # A run of episodes numbers the steps of each one from nought, so a frame
      # named by the step's own number is every episode's fourth step at once and
      # each episode wrote over the one before it. A replay of a hundred and forty
      # objects then showed the last one — banana — at every step.
      RunStream.publish(run_id, seeing(step: 4, episode: 0, depth: [[0.05, 0.07], [0.05, 0.07]]))
      :ok = drawn(run_id)

      assert {:ok, before} = Artifacts.frame_bytes(run_id, "0/patch-depth.png")

      RunStream.publish(run_id, seeing(step: 4, episode: 1, depth: [[0.05, 0.05], [0.05, 0.05]]))
      :ok = drawn(run_id)

      assert {[first_entry, second_entry], [first, second]} = RunStream.steps(run_id)
      assert {first_entry["episode"], second_entry["episode"]} == {0, 1}
      assert {first_entry["step"], second_entry["step"]} == {4, 4}

      assert %{"patch" => %{"images" => %{"depth" => first_frame}}} = first["sensors"]
      assert %{"patch" => %{"images" => %{"depth" => second_frame}}} = second["sensors"]

      assert first_frame == "/runs/#{run_id}/frames/0/patch-depth.png"
      assert second_frame == "/runs/#{run_id}/frames/1/patch-depth.png"

      # And the later episode's pictures are its own: the first step's frame is
      # still the surface of the first episode, not a second write over it.
      assert {:ok, ^before} = Artifacts.frame_bytes(run_id, "0/patch-depth.png")
      assert {:ok, other} = Artifacts.frame_bytes(run_id, "1/patch-depth.png")
      refute other == before
    end

    test "are drawn behind the step the page is shown", %{run_id: run_id} do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Studio.Jobs.Run.topic(run_id))

      RunStream.publish(run_id, seeing(depth: [[0.05, 0.07], [0.05, 0.07]]))

      assert_receive {:studio, ^run_id, {:step, announcement}}, 5_000
      assert [%{sensor_id: "patch", media_type: "text/html"}] = announcement.frames

      # The record already pointed at it; this is the bytes arriving.
      :ok = Pictures.settle()
      assert {:ok, png} = Artifacts.frame_bytes(run_id, "0/patch-depth.png")
      assert png |> binary_part(0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>
    end

    # Drawing two PNGs a sensor and base64ing them costs about as much again as
    # the archive's own planes, and it used to happen on every step — in the
    # process that stands between a run and its pages. The page is a player: it is
    # handed a picture at its own rate, and a step between two pictures announces
    # itself without any. The archive is not throttled, because its places are the
    # step numbers.
    test "are handed to a page at a display rate, while every step is archived", %{
      run_id: run_id
    } do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Studio.Jobs.Run.topic(run_id))

      # A minute between pictures: the first step is due, the second is not.
      Pictures.drawn(step(depth: [[0.05, 0.07], [0.05, 0.07]]), run_id, "0",
        frames_interval: 60_000
      )

      assert_receive {:studio, ^run_id, {:step, %{step: 1, frames: [_ | _]}}}, 5_000

      Pictures.drawn(step(step: 2, depth: [[0.05, 0.05], [0.05, 0.05]]), run_id, "1",
        frames_interval: 60_000
      )

      assert_receive {:studio, ^run_id, {:step, %{step: 2, frames: []}}}, 5_000

      :ok = Pictures.settle()
      assert {:ok, _first} = Artifacts.frame_bytes(run_id, "0/patch-depth.png")
      assert {:ok, _second} = Artifacts.frame_bytes(run_id, "1/patch-depth.png")
    end

    # The interval is a floor and the cost is the rest: a picture that took a
    # tenth of a second buys itself a tenth of a second, so the writer spends at
    # most half of its time drawing whatever a camera answers — which is what
    # keeps a view finder's picture from putting the writer behind the run.
    test "a picture that took a while buys itself a while before the next" do
      now = System.monotonic_time(:millisecond)

      assert Pictures.due?(nil, 0, 100)
      assert Pictures.due?(now - 200, 0, 100)
      refute Pictures.due?(now, 0, 100)
      refute Pictures.due?(now - 200, 300, 100)
      assert Pictures.due?(now - 350, 300, 100)
    end

    test "cost a run its pictures when one cannot be drawn, never the process", %{run_id: run_id} do
      # A camera that answers something no picture can be made of used to end the
      # writer, and with it the node: the supervisor restarted it into the same
      # step until it gave up. A frame named by something that is not a place is
      # the same kind of surprise, and the answer to it is one warning.
      step = seeing(depth: [[0.05, 0.07], [0.05, 0.07]])

      assert is_pid(Process.whereis(Pictures))
      Pictures.drawn(step, run_id, "run-patch-not-a-place")
      :ok = Pictures.settle()

      assert Process.alive?(Process.whereis(Pictures))
      assert Artifacts.videos(run_id) == []
    end

    # A step's observations are tens of megabytes of pixel lists and a run hands
    # over several while one step is drawn, so a writer that took every step would
    # queue the run's whole transcript of pixels: a page-started run of
    # `bright_world_image_on_scanned_model` queued 373 steps and held eighteen
    # gigabytes in the writer, and the machine went down with it.
    test "are not carried by a step handed to a writer that is behind" do
      step = seeing(depth: [[0.05, 0.07], [0.05, 0.07]])

      assert Pictures.carried(step, Pictures.backlog()) == step
      assert %{observations: %{}} = Pictures.carried(step, Pictures.backlog() + 1)
    end

    test "keep their place when a step arrives without its pixels", %{run_id: run_id} do
      # The skipped step writes no frame of its own, and the next step's picture
      # fills its place: frame n is still step n, so a video read back shows its
      # pictures a step behind rather than every picture under the wrong step.
      Pictures.drawn(step(depth: [[0.05, 0.07], [0.05, 0.07]]), run_id, "0", announce: false)
      :ok = Pictures.settle()

      skipped =
        step(step: 2, depth: [[0.9, 0.9], [0.9, 0.9]])
        |> Pictures.carried(Pictures.backlog() + 1)

      Pictures.drawn(skipped, run_id, "1", announce: false)

      Pictures.drawn(step(step: 3, depth: [[0.05, 0.05], [0.05, 0.05]]), run_id, "2",
        announce: false
      )

      :ok = Pictures.settle()

      assert {:ok, filled} = Artifacts.frame_bytes(run_id, "1/patch-depth.png")
      assert {:ok, own} = Artifacts.frame_bytes(run_id, "2/patch-depth.png")

      # The place the skipped step left is filled with the picture that came
      # **after** it — a fill from the one before would leave this unequal. The
      # first step's own frame is not a reference point here: this writer holds
      # every run on the node, so a suite running these cases side by side can
      # hand it that step without its pixels (`carried/2`, the case below), and
      # then the first place is filled too.
      assert filled == own
    end

    test "stop for the run whose picture failed, not for another's", %{run_id: run_id} do
      # One writer holds every run on the node, and a step it cannot draw used to
      # stop the streams already open — of every run — so one bad camera left the
      # other runs' videos short of the step that failed.
      other = Ecto.UUID.generate()
      :ok = Artifacts.start(other)
      on_exit(fn -> Artifacts.forget(other) end)

      Pictures.drawn(step(depth: [[0.05, 0.07], [0.05, 0.07]]), other, "0", announce: false)

      Pictures.drawn(step(depth: [[0.05, 0.07], [0.05, 0.07]]), run_id, "not-a-place",
        announce: false
      )

      :ok = Pictures.settle()

      Pictures.drawn(step(step: 2, depth: [[0.05, 0.05], [0.05, 0.05]]), other, "1",
        announce: false
      )

      :ok = Pictures.settle()

      assert {:ok, _png} = Artifacts.frame_bytes(other, "1/patch-depth.png")
    end
  end

  # Waits until the steps published so far have their pictures. The drawing
  # happens in another process and a cast reaches it from the stream's process,
  # so the stream is asked for its count first: an answer to that says the cast
  # was handed on, and only then is the drawing waited for.
  defp drawn(run_id) do
    _ = RunStream.count(run_id)
    Pictures.settle()
  end

  # A step, the way a worker hands one over: what it reported, what the modules
  # believed, what the sensors saw, and when.
  defp report(options) do
    %{
      info: %{
        step: Keyword.fetch!(options, :step),
        percept_ids: [:patch],
        inputs: %{learning_module_0: 1},
        votes: %{sent: 1, used: 1},
        goals: 0,
        actions: [:turn_left],
        duration_us: 140
      },
      at: Keyword.get(options, :at, @moment),
      episode: Keyword.get(options, :episode, 0),
      beliefs: Keyword.get(options, :beliefs, %{}),
      observations: Keyword.get(options, :observations, %{}),
      sensor_ids: Keyword.get(options, :sensor_ids, []),
      centre: nil
    }
  end
end
