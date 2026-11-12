defmodule Monty.Studio.RunStream.Pictures do
  @moduledoc """
  The pictures of a run's steps, drawn and written after the step is recorded.

  A step's record keeps the *name* of each of its pictures — the run's own
  convention, `<step>/<sensor>-<depth|colour>.png` — and this process makes the
  bytes, writes them, and announces the step to whatever page is watching. It is
  a process of its own because a boundary asks `RunStream` for everything it has
  been handed, and that barrier was waiting behind a JPEG per sensor per step:
  1.2–1.7 ms to encode and 0.8–1.0 ms to write, per step, for every step still
  in the queue when the boundary arrived.

  One process, and ordered, for two reasons: a page is handed its steps in the
  order they were taken, and a run's pictures are written under names it shares,
  so two steps of one run must not race each other.

  A picture the filesystem refuses is a warning rather than an exception: the
  record already names it, and a run that cannot write a picture is still a run
  whose numbers are right.
  """

  use GenServer

  require Logger

  alias Monty.Simulators.Synthetic.Camera
  alias Monty.Studio.{Artifacts, RunLog}

  @doc """
  Draws and writes a step's pictures, and announces the step.

  A `cast`: by the time this is called the step is in the run's table and its
  line is in the log, and neither of them waits for a picture.
  """
  @spec drawn(map(), binary(), String.t()) :: :ok
  def drawn(step, pictures_in, frame) do
    GenServer.cast(__MODULE__, {:drawn, step, pictures_in, frame})
  end

  @doc """
  Waits until every step handed over so far has its pictures.

  For a caller that is about to look at the files rather than at the record: the
  record has their names already, which is the point of the arrangement.
  """
  @spec settle() :: :ok
  def settle, do: GenServer.call(__MODULE__, :settle)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:drawn, step, pictures_in, frame}, state) do
    images = images_of(step)
    write(pictures_in, frame, images)
    broadcast(pictures_in, {:step, announcement(step, frames_of(step, images))})
    {:noreply, state}
  end

  @impl true
  def handle_call(:settle, _from, state), do: {:reply, :ok, state}

  # Every sensor, every step: the four pixels arrays become two pictures a sensor,
  # and the range the depth one is drawn over.
  defp images_of(step) do
    step.observations
    |> RunLog.sensors_of()
    |> Map.new(fn {sensor_id, observation} ->
      {sensor_id, Camera.images(observation)}
    end)
  end

  defp write(run_id, frame, images) do
    for {sensor_id, sensor} <- images,
        {kind, base64} <- [{"depth", sensor.depth}, {"colour", sensor.colour}],
        is_binary(base64) do
      case Artifacts.put_frame(run_id, frame, sensor_id, kind, base64) do
        {:ok, _name} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "studio run #{run_id}: cannot write the #{kind} picture of step #{frame}: " <>
              inspect(reason)
          )
      end
    end
  end

  # What a page draws a step from: its line, the pictures, and what the learning
  # modules concluded. The observations themselves stay in `RunStream.steps/1`,
  # where a replay reads them.
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

  # Every sensor, every step. A queued run has no socket waiting on it, so there
  # is nothing to throttle for; the frames are not thumbnails either — they are
  # the same drawing a live page would get. The observation carries the pictures
  # this step already encoded, so `Camera.frame/3` draws them rather than making
  # its own: a step pays for two PNGs a sensor, not four.
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
