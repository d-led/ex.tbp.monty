defmodule Monty.Studio.RunHistory.Compaction do
  @moduledoc """
  A moment that carried its pictures as bytes, rewritten to carry their names.

  A record's moment used to hold the two PNGs a sensor drew, base64 and inline —
  ten kilobytes a step, which put `base_10simobj_surf_agent` within four percent
  of Postgres's 256 MB ceiling on one `jsonb` value and put a
  twenty-two-thousand-step run past it, where the store fails and the run keeps
  no record at all. `Monty.Studio.Artifacts.put_frame/5` moved them to
  `frames/<step>/<sensor>-<kind>.png` beside the run's log, and the row keeps the
  URL: **701 bytes a moment** against **13 687** measured on a row written
  before the change.

  Rows written before it still hold the bytes. In one studio's file three of them
  held **289 MB** of timeline between them, and a moment that size costs what it
  always did — `get/1` decodes it, a page opening the run waits for it, and on
  SQLite any write to the row rewrites it whole, pictures and all.

  This turns a legacy moment into the shape the writer produces today, and hands
  back the pictures that have to be written to disk first: nothing is rewritten
  until its bytes are a file, so a compaction that fails half way leaves the row
  as it was.
  """

  alias ExTbpMonty.Repo
  alias ExTbpMonty.Repo

  alias Monty.Studio.Artifacts

  @kinds ["colour", "depth"]

  @typedoc "One picture a legacy moment holds and the record should name instead."
  @type picture :: %{
          step: term(),
          sensor_id: String.t(),
          kind: String.t(),
          base64: String.t()
        }

  @doc """
  The same moment with its pictures named, and the pictures to write first.

  A moment already in today's shape comes back untouched with nothing to write,
  which is what makes a second run of the compaction a no-op rather than a
  rewrite of every row.
  """
  @spec compact(binary(), map()) :: {map(), [picture()]}
  def compact(run_id, %{"sensors" => sensors} = moment) when is_map(sensors) do
    {sensors, pictures} =
      Enum.reduce(sensors, {sensors, []}, fn {sensor_id, observation}, {sensors, pictures} ->
        {observation, new_pictures} =
          compact_sensor(run_id, moment["step"], sensor_id, observation)

        {Map.put(sensors, sensor_id, observation), pictures ++ new_pictures}
      end)

    {Map.put(moment, "sensors", sensors), pictures}
  end

  def compact(_run_id, moment), do: {moment, []}

  @doc "Whether a moment still holds a picture as bytes."
  @spec legacy?(map()) :: boolean()
  def legacy?(%{"sensors" => sensors}) when is_map(sensors) do
    Enum.any?(sensors, fn {_sensor_id, observation} ->
      case observation do
        %{"images" => images} when is_map(images) ->
          Enum.any?(@kinds, fn kind -> images |> Map.get(kind) |> held_as_bytes?() end)

        _not_an_observation ->
          false
      end
    end)
  end

  def legacy?(_moment), do: false

  @doc """
  Compacts one run's record: writes the pictures it still holds as bytes, then
  writes the moments that name them.

  The write order is the point. A picture is on disk before the moment stops
  carrying it, and a run is updated only when every one of its pictures was
  written — so a failure leaves the record as it was rather than a record that
  lost pictures it can no longer show.
  """
  @spec apply_to(map()) :: {:ok, map()} | {:error, term()}
  def apply_to(%{id: id, timeline: moments} = run) when is_list(moments) do
    before_bytes = byte_size(Jason.encode!(moments))
    pictures = Enum.flat_map(moments, &(compact(id, &1) |> elem(1)))
    compacted = Enum.map(moments, &(compact(id, &1) |> elem(0)))

    case write(id, pictures) do
      :ok ->
        after_bytes = byte_size(Jason.encode!(compacted))

        with {:ok, saved} <- update(run, compacted) do
          {:ok,
           %{
             run: saved,
             pictures: length(pictures),
             before_bytes: before_bytes,
             after_bytes: after_bytes
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_to(%{timeline: nil} = run),
    do: {:ok, %{run: run, pictures: 0, before_bytes: 0, after_bytes: 0}}

  defp write(run_id, pictures) do
    Enum.reduce_while(pictures, :ok, fn %{
                                          step: step,
                                          sensor_id: sensor,
                                          kind: kind,
                                          base64: base64
                                        },
                                        :ok ->
      case Artifacts.put_frame(run_id, step, sensor, kind, base64) do
        {:ok, _name} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {step, sensor, kind, reason}}}
      end
    end)
  end

  defp update(run, timeline) do
    run
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:timeline, timeline)
    |> Repo.update()
  end

  defp held_as_bytes?(value) when is_binary(value) and value != "", do: inline?(value)
  defp held_as_bytes?(_absent), do: false

  defp compact_sensor(run_id, step, sensor_id, %{"images" => images} = observation)
       when is_map(images) do
    {images, pictures} =
      Enum.reduce(@kinds, {images, []}, fn kind, {images, pictures} ->
        compact_picture(run_id, step, sensor_id, kind, images, pictures)
      end)

    {Map.put(observation, "images", images), pictures}
  end

  defp compact_sensor(_run_id, _step, _sensor_id, observation), do: {observation, []}

  defp compact_picture(run_id, step, sensor_id, kind, images, pictures) do
    case Map.get(images, kind) do
      value when is_binary(value) and value != "" ->
        if inline?(value) do
          # The name `put_frame/5` writes and `frame_url/2` serves, so a compacted
          # moment is what a run of today's code would have written.
          name = Path.join(to_string(step), "#{sensor_id}-#{kind}.png")

          {Map.put(images, kind, Artifacts.frame_url(run_id, name)),
           pictures ++ [%{step: step, sensor_id: sensor_id, kind: kind, base64: bytes(value)}]}
        else
          {images, pictures}
        end

      _absent ->
        {images, pictures}
    end
  end

  # A URL starts at the root; anything else is bytes, with or without the prefix
  # a page would put on a `src`.
  defp inline?(value), do: not String.starts_with?(value, "/")

  defp bytes("data:image/png;base64," <> base64), do: base64
  defp bytes(base64), do: base64
end
