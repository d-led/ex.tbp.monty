defmodule Monty.Studio.RunStream.Pictures do
  @moduledoc """
  The pictures of a run's steps: kept as video, and announced to whatever page is
  watching.

  A step's record keeps the *name* of each of its pictures — the run's own
  convention, `<place>/<sensor>-<depth|colour>.png` — and this process is what
  puts bytes behind those names. The names did not change; what they resolve to
  did. It used to write a PNG a picture, four files a step: one measured run of
  53 826 steps left **215 304 files taking 882 MB of disk for 48.7 MB of
  pixels**, because a 100-byte picture still costs a whole block, an inode and a
  metadata write. It now appends each picture to a video a sensor — about fifty
  bytes a frame, and an index beside it — and `Monty.Studio.Artifacts.frame_bytes/2`
  decodes a step's frame out of it when a page asks.

  ## The invariant: a picture's frame is its place in the run

  A step's frame number is read out of the name the record kept
  (`Artifacts.picture/1`), so a video has to hold exactly one frame a step, in
  step order. Two things follow, and both are deliberate:

    * a picture is written for **every** step, even when the writer is behind and
      the page is not being given one — a dropped frame would shift every frame
      after it, and the page would draw one step's picture under another's name;
    * a sensor that first sees something mid-run is **back-filled** with that
      picture, so its frames still line up with the places the record names.

  A video this run already wrote is continued rather than overwritten — a worker
  restarted, a part handed to another node. If it already holds *more* frames
  than the place, the run's own counter restarted (the defect `RunStream` still
  has, `frame_key/2`), and this refuses to write: a picture that is missing is
  better than a picture of the wrong step, and the warning names the file.

  ## The page is a player, not an archive

  A step's pictures are archived for **every** step — the video's places are the
  step numbers — but the page is handed one at a rate of its own
  (`:studio_frames_interval`, ten a second by default), because a page draws the
  newest picture and a run steps tens of times a second. A page's picture is
  encoded from the same pixels the video took, so a step is walked once; walking
  the observation a second time for the page was most of what a page's step cost.
  Even then it is tens of milliseconds a sensor at a view finder's size, which is
  why it is a page's refresh rather than a step's.

  ## Why a process of its own

  A boundary asks `RunStream` for everything it has been handed, and that barrier
  was waiting behind a JPEG per sensor per step: 1.2–1.7 ms to encode and 0.8–1.0
  ms to write, per step, for every step still in the queue when the boundary
  arrived. A frame now costs 0.02 ms to encode and is flushed with its fragment,
  so the queue stays short — but the announcement order is still this process's,
  which is what a page draws.

  A picture the filesystem refuses is a warning rather than an exception: the
  record already names it, and a run that cannot write a picture is still a run
  whose numbers are right.

  ## What the writer never keeps

  A step's observations are the camera's picture as lists of numbers — tens of a
  megabyte for four planes of two sensors — and this process draws one step at a
  time. A run hands over ten steps while one is drawn, so a queue that accepts
  every step is a queue that grows until the machine gives up: a page-started run
  queued 373 steps of about 37 MB each and held eighteen gigabytes in one
  process (`docs/monty-differences.md` §2.42). Past `@backlog` a step therefore
  travels **without its observations** (`carried/2`) and draws nothing — neither
  a frame of the video nor a picture for the page. The video's places keep their
  step numbers (`append/4` fills the places a skipped step left), and the page
  keeps the pictures it has.
  """

  use GenServer

  require Logger

  alias ExTbpMonty.Core.FrameVideo
  alias Monty.Simulators.Synthetic.Camera
  alias Monty.Studio.{Artifacts, RunLog}

  # Idle here for the reason `RunWriter`'s comment measures: this process draws
  # and encodes every step's pictures, so its heap is the size of the batch that
  # took longest.
  @idle_after Application.compile_env(:ex_tbp_monty, :studio_idle_hibernate_after, 5_000)

  # How far behind the steps the writer may get before it stops taking their
  # pixels: about a second of a stepping run, which is the point after which its
  # pictures are of steps nobody is watching. A step past this is handed over
  # without its observations (§ `carried/2`) and writes no frame of its own; the
  # next step fills its place, so the video stays one frame a step.
  #
  # The number is also the writer's memory: kept pixels are about forty megabytes
  # a step where a camera answers at full size — four planes of two sensors as
  # lists of numbers — so six steps is a quarter of a gigabyte at worst, against
  # the eighteen the same six minutes took with an open queue
  # (`docs/monty-differences.md` §2.42).
  @backlog 6

  # How long after the last frame the writer writes what it holds. A keyframe
  # writes its own fragment; the frames between two of them are in this process
  # until something says otherwise, and a run that ends mid-fragment would leave
  # its last steps unreadable. Two seconds is longer than a gap between steps and
  # shorter than a person's patience.
  @flush_after 2_000

  @typedoc """
  What is remembered between steps: the video open for each sensor and kind, the
  episode the last frame of each stream belonged to, when the page watching a run
  was last given a picture, and the streams that cannot be written any more.
  """
  @type state :: %{
          videos: %{term() => reference()},
          episodes: %{term() => term()},
          frames_at: %{binary() => integer()},
          frames_cost: %{binary() => non_neg_integer()},
          stalled: MapSet.t(),
          refused: MapSet.t(),
          flushing: reference() | nil
        }

  # How often a page watching a run is handed a picture, in milliseconds: ten a
  # second is a video's rate, and it is the page's rate rather than the step's.
  # Zero is every step, which is what the suite asks for.
  @frames_interval_default 100

  @doc """
  How often a page is handed a picture, in milliseconds.

  The setting is the deployment's (`:studio_frames_interval`), because how fast a
  page should refresh is not a run's decision.
  """
  @spec frames_interval() :: non_neg_integer()
  def frames_interval,
    do: Application.get_env(:ex_tbp_monty, :studio_frames_interval, @frames_interval_default)

  @doc """
  Whether a page watching a run is due another picture.

  `nil` is a page that has not been given one yet. Otherwise the answer is yes
  once the interval has passed **or** as long as drawing the last picture took,
  whichever is longer: a picture that costs a tenth of a second buys itself a
  tenth of a second before the next, so the writer never spends more than half of
  its time drawing and never falls behind a run — the rule a player drops frames
  by, and what makes a view finder's picture affordable at all.
  """
  @spec due?(integer() | nil, non_neg_integer(), non_neg_integer()) :: boolean()
  def due?(nil, _cost, _interval), do: true
  def due?(at, cost, interval), do: now() - at >= max(interval, cost)

  @doc """
  Draws and writes a step's pictures, and announces the step.

  A `cast`: by the time this is called the step is in the run's table and its
  line is in the log, and neither of them waits for a picture.

  `announce?: false` is a run nobody is watching — `mix monty.run` records its
  steps itself and has no page to push a frame to — and it draws nothing for the
  page: only the video is written.

  `:frames_interval` is how long the page's last picture must be old for this
  step's pictures to be worth drawing (milliseconds; `frames_interval/0` by
  default). A step inside the interval still announces its line and its beliefs.
  """
  @spec drawn(map(), binary(), String.t(), keyword()) :: :ok
  def drawn(step, pictures_in, frame, options \\ []) do
    announce? = Keyword.get(options, :announce, true)
    interval = Keyword.get(options, :frames_interval, frames_interval())

    GenServer.cast(
      __MODULE__,
      {:drawn, carried(step, queued()), pictures_in, frame, announce?, interval}
    )
  end

  @doc """
  The step as it is handed over: with its pixels only while the writer can use
  them.

  A step's observations are tens of megabytes — a camera's picture as lists of
  numbers, four planes a sensor — and the writer draws one step at a time. A run
  at its fastest hands over ten steps while one is drawn, so an unbounded queue
  of them is what took a workstation to 35 GB: a page Started run of
  `bright_world_image_on_scanned_model` queued 373 steps of about 37 MB each,
  more than ten gigabytes, in a process that then held them while it drew.

  Past `@backlog` the step travels **without its observations**: the writer takes
  that as "write no frame for this place", which costs the video a repeated
  picture rather than its alignment (see `append/4`), and costs the queue a name
  rather than a picture.
  """
  @spec carried(map(), non_neg_integer()) :: map()
  def carried(step, queued) when queued > @backlog, do: Map.put(step, :observations, %{})
  def carried(step, _queued), do: step

  @doc """
  Whether the writer is further behind than the page can use.

  Asked before a step is drawn for a page: the newest picture is the one worth
  drawing, and drawing the ones nobody is looking at is what keeps the writer
  behind.
  """
  @spec behind?() :: boolean()
  def behind?, do: queued() > @backlog

  # A process that is not running has nothing queued; a step is still handed to
  # the supervisor's next start rather than dropped.
  defp queued do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:message_queue_len, queued} <- Process.info(pid, :message_queue_len) do
      queued
    else
      _ -> 0
    end
  end

  @doc """
  Waits until every step handed over so far has its pictures.

  For a caller that is about to look at the files rather than at the record: the
  record has their names already, which is the point of the arrangement. A frame
  between two keyframes sits in a fragment that is not on disk yet, so this
  flushes before it answers — a picture is only readable once it is written.
  """
  @spec settle(timeout()) :: :ok
  def settle(timeout \\ 5_000), do: GenServer.call(__MODULE__, :settle, timeout)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: @idle_after)
  end

  @doc """
  How many steps the writer may fall behind before it stops taking their pixels.

  A run of twenty thousand steps is eighty thousand pictures; a page can only
  show one step at a time, the picture that matters is the newest one, and the
  pixels of the ones between are tens of a megabyte each.
  """
  @spec backlog() :: non_neg_integer()
  def backlog, do: @backlog

  @impl true
  def init(_opts),
    do:
      {:ok,
       %{
         videos: %{},
         episodes: %{},
         frames_at: %{},
         frames_cost: %{},
         stalled: MapSet.new(),
         refused: MapSet.new(),
         flushing: nil
       }}

  @impl true
  def handle_cast({:drawn, step, pictures_in, frame, announce?, interval}, state) do
    {:noreply, draw(step, pictures_in, frame, announce?, interval, state)}
  end

  # A picture is never worth the run, and never worth the node: a step this
  # process cannot draw costs that run its pictures and nothing else. Dying here
  # would be worse than losing a video — the supervisor would restart it into the
  # same step until it gave up, and the application would go with it, which is how
  # a MuJoCo run's wrong-sized channel ended a whole node.
  defp draw(step, pictures_in, frame, announce?, interval, state) do
    planes = planes_of(step)
    state = write(step, pictures_in, frame, planes, state) |> schedule_flush()
    {frames, state} = page_frames(step, planes, pictures_in, interval, state)

    # What a page draws a step from: its line, the pictures, and what the learning
    # modules concluded. The observations themselves stay in `RunStream.steps/1`,
    # where a replay reads them. A queued run has no socket waiting, its frames
    # are the same drawing a live page would get, and a step pays for two PNGs a
    # sensor rather than four because the step already encoded its pixels.
    if announce? do
      broadcast(pictures_in, {:step, announcement(step, frames)})
    end

    state
  rescue
    exception -> stop_pictures(step, pictures_in, state, Exception.message(exception))
  catch
    kind, reason -> stop_pictures(step, pictures_in, state, "#{kind} #{inspect(reason)}")
  end

  # Said once a run, not once a step: a camera that answers the same way every
  # step would otherwise write the same warning twenty thousand times. The streams
  # already open are stopped with it, because a picture missing is better than one
  # step's picture under another's number — but only the streams of the run whose
  # picture failed: one writer serves every run on the node, and a run whose camera
  # answered badly is no reason to stop another's archive.
  defp stop_pictures(step, pictures_in, state, why) do
    if MapSet.member?(state.refused, pictures_in) do
      state
    else
      Logger.warning(
        "studio run pictures: the pictures of run #{inspect(pictures_in)} stop at " <>
          "step #{Map.get(step, :number, "?")}: #{why}"
      )

      stalled = Enum.reduce(streams_of(pictures_in, state), state.stalled, &MapSet.put(&2, &1))
      %{state | refused: MapSet.put(state.refused, pictures_in), stalled: stalled}
    end
  end

  defp streams_of(run, state) do
    state.videos
    |> Map.keys()
    |> Enum.filter(fn {held, _part, _sensor, _named} -> held == run end)
  end

  @impl true
  def handle_call(:settle, _from, state) do
    Enum.each(state.videos, fn {_key, video} -> flush(video) end)

    {:reply, :ok, %{state | flushing: nil}}
  end

  # The frames since the last keyframe, written because the steps stopped coming.
  @impl true
  def handle_info(:flush_pending, state) do
    Enum.each(state.videos, fn {_key, video} -> flush(video) end)

    {:noreply, %{state | flushing: nil}}
  end

  defp schedule_flush(%{flushing: nil} = state) do
    %{state | flushing: Process.send_after(self(), :flush_pending, @flush_after)}
  end

  defp schedule_flush(state), do: state

  defp flush(video) do
    case FrameVideo.flush(video) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("studio run pictures: cannot flush: #{inspect(reason)}")
    end
  end

  # A page shows the newest step's pictures at the rate it can draw them. A step
  # inside the interval announces itself without pictures, so a run that steps
  # faster than a page refreshes does not pay for the drawing it cannot show:
  # the archive still has every step's frame, because the video is written above,
  # before this is asked. A writer this far behind is drawing steps nobody looks
  # at, and answering with no frames leaves the page's pictures where they are.
  defp page_frames(step, planes, run, interval, state) do
    cond do
      behind?() ->
        {[], state}

      due?(Map.get(state.frames_at, run), Map.get(state.frames_cost, run, 0), interval) ->
        {microseconds, frames} = :timer.tc(fn -> frames_of(step, planes) end)

        {frames,
         %{
           state
           | frames_at: Map.put(state.frames_at, run, now()),
             frames_cost: Map.put(state.frames_cost, run, div(microseconds, 1000))
         }}

      true ->
        {[], state}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # One walk a sensor a step, however many pictures are made of it: the video takes
  # the planes and the page's pictures are encoded from the same bytes. Walking the
  # observation again for the page was most of a page's step.
  defp planes_of(step) do
    step.observations
    |> RunLog.sensors_of()
    |> Map.new(fn {sensor_id, observation} -> {sensor_id, Camera.planes(observation || %{})} end)
  end

  # One picture a step a sensor a kind, in the order the steps were taken.
  defp write(step, pictures_in, frame, planes, state) do
    place = %{
      run: pictures_in,
      part: Artifacts.part_of(frame),
      position: position_of(frame),
      episode: Map.get(step, :episode)
    }

    Enum.reduce(planes, state, fn {sensor_id, sensor_planes}, state ->
      write_sensor(state, sensor_id, sensor_planes, Map.put(place, :sensor, sensor_id))
    end)
  end

  defp position_of(frame), do: frame |> String.split("-") |> List.last() |> String.to_integer()

  defp write_sensor(state, _sensor_id, planes, place) do
    Enum.reduce(
      [{"depth", :grey, planes.depth}, {"colour", :rgb, planes.colour}],
      state,
      fn {named, kind, plane}, state ->
        write_picture(state, plane, place, {named, kind})
      end
    )
  end

  defp write_picture(state, nil, _place, _kind), do: state

  defp write_picture(state, plane, place, {named, kind}) do
    key = {place.run, place.part, place.sensor, named}

    with false <- MapSet.member?(state.stalled, key),
         {:ok, state} <- ensure_video(state, key, plane, place, {named, kind}) do
      append(state, key, plane.pixels, place)
    else
      true -> state
      {:error, state} -> state
    end
  end

  # A video opens where the run's places are, not where the writer happens to
  # start: a sensor that first sees something at step 40 gets 40 frames of that
  # picture before the real one, so frame 40 is step 40.
  defp ensure_video(state, key, plane, place, {named, kind}) do
    case Map.fetch(state.videos, key) do
      {:ok, _video} ->
        {:ok, state}

      :error ->
        path = Artifacts.video_path(place.run, place.part, place.sensor, named)

        with {:ok, video} <-
               FrameVideo.open(path, width: plane.width, height: plane.height, kind: kind),
             :ok <- fill_to(video, plane.pixels, FrameVideo.frames(video), place.position) do
          {:ok, %{state | videos: Map.put(state.videos, key, video)}}
        else
          {:error, reason} -> {:error, refuse(state, key, path, reason)}
        end
    end
  end

  defp fill_to(_video, _pixels, have, want) when have > want, do: {:error, {:ahead, have, want}}

  defp fill_to(video, pixels, have, want) do
    case push_many(video, pixels, want - have) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp push_many(_video, _pixels, 0), do: :ok

  defp push_many(video, pixels, count) do
    Enum.reduce_while(1..count, :ok, fn _frame, :ok ->
      case FrameVideo.push(video, pixels, false) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A step handed over without its pixels (§ `carried/2`) writes no frame of its
  # own, so the places before this one are filled with this step's picture: frame
  # n is still step n, and the video is a step behind in content rather than out
  # of step — which is what a saved video is read for.
  defp append(state, key, pixels, place) do
    video = Map.fetch!(state.videos, key)

    with :ok <- pad_to(video, pixels, place.position),
         :ok <- FrameVideo.push(video, pixels, keyframe?(state, place)) do
      %{state | episodes: Map.put(state.episodes, stream_of(place), place.episode)}
    else
      {:error, reason} -> refuse(state, key, key, reason)
    end
  end

  defp pad_to(video, pixels, position) do
    case position - FrameVideo.frames(video) do
      missing when missing > 0 -> push_many(video, pixels, missing)
      _written -> :ok
    end
  end

  # An episode's first frame is a new object in a new place, which is exactly
  # where a seek should be able to start. The encoder keys at least every `:gop`
  # frames anyway, so this only adds the discontinuities nobody had to detect.
  defp keyframe?(state, place) do
    case Map.fetch(state.episodes, stream_of(place)) do
      {:ok, episode} -> episode != place.episode
      :error -> true
    end
  end

  defp stream_of(place), do: {place.run, place.part}

  # A stream that cannot be written is written off once, with the reason: every
  # later step would repeat the same warning, and the run keeps stepping.
  defp refuse(state, key, label, reason) do
    Logger.warning("studio run pictures: cannot write #{inspect(label)}: #{inspect(reason)}")

    %{state | videos: Map.delete(state.videos, key), stalled: MapSet.put(state.stalled, key)}
  end

  defp announcement(step, frames) do
    %{
      line: step.line,
      episode: step.episode,
      step: step.number,
      frames: frames,
      beliefs: step.beliefs,
      centre: step.centre
    }
  end

  # Every sensor, every step — from the pixels the archive already walked. The
  # pictures are the video's own bytes, encoded once, and the range on the note is
  # the range that same walk found.
  defp frames_of(step, planes) do
    seen = RunLog.sensors_of(step.observations)

    step.sensor_ids
    |> Enum.filter(&Map.has_key?(planes, &1))
    |> Enum.map(fn sensor_id ->
      observation = Map.get(seen, sensor_id) || %{}
      pictures = Camera.pictures(planes[sensor_id])

      Camera.frame(sensor_id, RunLog.drawn(observation, pictures), step.number)
    end)
    |> Enum.map(&Map.take(&1, [:sensor_id, :media_type, :data, :note]))
  end

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      Monty.Studio.Jobs.Run.topic(run_id),
      {:studio, run_id, event}
    )
  end
end
