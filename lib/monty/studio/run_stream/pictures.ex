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

  # How far behind the steps the writer may get before it stops drawing the
  # pictures a page draws: about a second of a stepping run, which is the point
  # after which its pictures are of steps nobody is watching. The video is
  # written either way — that is the invariant above, not a preference.
  @backlog 20

  # How long after the last frame the writer writes what it holds. A keyframe
  # writes its own fragment; the frames between two of them are in this process
  # until something says otherwise, and a run that ends mid-fragment would leave
  # its last steps unreadable. Two seconds is longer than a gap between steps and
  # shorter than a person's patience.
  @flush_after 2_000

  @typedoc """
  What is remembered between steps: the video open for each sensor and kind, the
  episode the last frame of each stream belonged to, and the streams that cannot
  be written any more.
  """
  @type state :: %{
          videos: %{term() => reference()},
          episodes: %{term() => term()},
          stalled: MapSet.t(),
          refused: MapSet.t(),
          flushing: reference() | nil
        }

  @doc """
  Draws and writes a step's pictures, and announces the step.

  A `cast`: by the time this is called the step is in the run's table and its
  line is in the log, and neither of them waits for a picture.

  `announce?: false` is a run nobody is watching — `mix monty.run` records its
  steps itself and has no page to push a frame to — and it draws nothing for the
  page: only the video is written.
  """
  @spec drawn(map(), binary(), String.t(), keyword()) :: :ok
  def drawn(step, pictures_in, frame, options \\ []) do
    announce? = Keyword.get(options, :announce, true)
    GenServer.cast(__MODULE__, {:drawn, step, pictures_in, frame, announce?})
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
  How many steps the writer may fall behind before it stops drawing every one.

  A run of twenty thousand steps is eighty thousand pictures; a page can only
  show one step at a time, and the picture that matters is the newest one.
  """
  @spec backlog() :: non_neg_integer()
  def backlog, do: @backlog

  @impl true
  def init(_opts),
    do:
      {:ok,
       %{videos: %{}, episodes: %{}, stalled: MapSet.new(), refused: MapSet.new(), flushing: nil}}

  @impl true
  def handle_cast({:drawn, step, pictures_in, frame, announce?}, state) do
    {:noreply, draw(step, pictures_in, frame, announce?, state)}
  end

  # A picture is never worth the run, and never worth the node: a step this
  # process cannot draw costs that run its pictures and nothing else. Dying here
  # would be worse than losing a video — the supervisor would restart it into the
  # same step until it gave up, and the application would go with it, which is how
  # a MuJoCo run's wrong-sized channel ended a whole node.
  defp draw(step, pictures_in, frame, announce?, state) do
    state = write(step, pictures_in, frame, state) |> schedule_flush()

    # What a page draws a step from: its line, the pictures, and what the learning
    # modules concluded. The observations themselves stay in `RunStream.steps/1`,
    # where a replay reads them. A queued run has no socket waiting, its frames
    # are the same drawing a live page would get, and a step pays for two PNGs a
    # sensor rather than four because the step already encoded its pixels.
    if announce? do
      images = if behind?(), do: %{}, else: images_of(step)
      broadcast(pictures_in, {:step, announcement(step, frames_of(step, images))})
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
  # step's picture under another's number.
  defp stop_pictures(step, pictures_in, state, why) do
    if MapSet.member?(state.refused, pictures_in) do
      state
    else
      Logger.warning(
        "studio run pictures: the pictures of run #{inspect(pictures_in)} stop at " <>
          "step #{Map.get(step, :number, "?")}: #{why}"
      )

      stalled = Enum.reduce(Map.keys(state.videos), state.stalled, &MapSet.put(&2, &1))
      %{state | refused: MapSet.put(state.refused, pictures_in), stalled: stalled}
    end
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

  defp behind? do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, queued} -> queued > @backlog
      _unknown -> false
    end
  end

  # One picture a step a sensor a kind, in the order the steps were taken.
  defp write(step, pictures_in, frame, state) do
    place = %{
      run: pictures_in,
      part: Artifacts.part_of(frame),
      position: position_of(frame),
      episode: Map.get(step, :episode)
    }

    seen = RunLog.sensors_of(step.observations)

    Enum.reduce(seen, state, fn {sensor_id, observation}, state ->
      write_sensor(state, sensor_id, observation, Map.put(place, :sensor, sensor_id))
    end)
  end

  defp position_of(frame), do: frame |> String.split("-") |> List.last() |> String.to_integer()

  defp write_sensor(state, _sensor_id, observation, place) do
    planes = Camera.planes(observation || %{})

    Enum.reduce(
      [{"depth", :grey, planes.depth}, {"colour", :rgb, planes.colour}],
      state,
      fn {named, kind, pixels}, state ->
        write_picture(state, pixels, place, {named, kind}, planes)
      end
    )
  end

  defp write_picture(state, nil, _place, _kind, _planes), do: state

  defp write_picture(state, pixels, place, {named, kind}, planes) do
    key = {place.run, place.part, place.sensor, named}

    with false <- MapSet.member?(state.stalled, key),
         {:ok, state} <- ensure_video(state, key, pixels, place, planes, {named, kind}) do
      append(state, key, pixels, place)
    else
      true -> state
      {:error, state} -> state
    end
  end

  # A video opens where the run's places are, not where the writer happens to
  # start: a sensor that first sees something at step 40 gets 40 frames of that
  # picture before the real one, so frame 40 is step 40.
  defp ensure_video(state, key, pixels, place, planes, {named, kind}) do
    case Map.fetch(state.videos, key) do
      {:ok, _video} ->
        {:ok, state}

      :error ->
        path = Artifacts.video_path(place.run, place.part, place.sensor, named)

        with {:ok, video} <-
               FrameVideo.open(path, width: planes.width, height: planes.height, kind: kind),
             :ok <- fill_to(video, pixels, FrameVideo.frames(video), place.position) do
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

  defp append(state, key, pixels, place) do
    video = Map.fetch!(state.videos, key)

    case FrameVideo.push(video, pixels, keyframe?(state, place)) do
      :ok ->
        %{state | episodes: Map.put(state.episodes, stream_of(place), place.episode)}

      {:error, reason} ->
        refuse(state, key, key, reason)
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

  # Every sensor, every step: the four pixel arrays become two pictures a sensor,
  # and the range the depth one is drawn over.
  defp images_of(step) do
    step.observations
    |> RunLog.sensors_of()
    |> Map.new(fn {sensor_id, observation} -> {sensor_id, Camera.images(observation)} end)
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

  # Every sensor, every step. The observation carries the pictures this step
  # already encoded, so `Camera.frame/3` draws them rather than making its own.
  defp frames_of(step, images) do
    seen = RunLog.sensors_of(step.observations)

    step.sensor_ids
    |> Enum.filter(&Map.has_key?(seen, &1))
    |> Enum.map(&Camera.frame(&1, RunLog.drawn(seen[&1], Map.get(images, &1)), step.number))
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
