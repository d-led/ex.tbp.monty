defmodule Monty.Simulators.Synthetic.Camera do
  @moduledoc """
  What a sensor saw, as a picture a page can show.

  The world renders depth, colour and semantic id per pixel; this turns the first
  two into images. Monty's own dashboards do the same thing — the PyView prototype
  this studio follows puts a base64 PNG of the camera and one of the depth image
  side by side — and for good reason: an image is the only way to see a *wrong*
  percept rather than infer one.

  Depth is drawn as greyscale over the frame's own range, and the range is written
  on the frame, because a depth image of a close surface is otherwise a flat grey
  square that says nothing. Pixels where nothing was seen (depth 0, which is what
  Monty's depth images use for "no return") are black, so an object against empty
  space reads as an object against empty space.

  A frame's `data` is markup the page may interpolate as it stands. Everything in
  it that is not a number of ours is escaped here, at the point the string is
  built — a template that had to remember to escape it could forget.
  """

  alias Monty.Studio.Png

  @type frame :: %{
          sensor_id: String.t(),
          step: non_neg_integer(),
          media_type: String.t(),
          data: Phoenix.HTML.Safe.t(),
          location: [float()],
          note: String.t()
        }

  @doc """
  The view from one sensor at one step.

  `observation` is the world's own: `"depth"` and `"rgba"` are images, one list per
  per row. An observation that carries `"images"` instead has already been drawn —
  a recorded step keeps the pictures rather than the four thousand numbers a step
  they came from — and is shown as it was drawn.
  """
  @spec frame(String.t(), map(), non_neg_integer()) :: frame()
  def frame(sensor_id, observation, step) do
    %{
      sensor_id: sensor_id,
      step: step,
      media_type: "text/html",
      data: markup(sensor_id, images(observation)),
      location: Map.get(observation, "location", [0.0, 0.0, 0.0]),
      note: note(step, observation)
    }
  end

  @doc """
  The pictures a sensor's observation makes, base64 PNGs and the depth range.

  Answers `%{depth: nil, colour: nil, range: nil}` when the observation carries
  nothing to draw — a world with no scene, or a recorded step from before runs
  kept their pictures — because a frame that said nothing about what it was
  looking at would be worse than one that says there is nothing.
  """
  @spec images(map()) :: %{
          depth: String.t() | nil,
          colour: String.t() | nil,
          range: {float(), float()} | nil
        }
  def images(observation) do
    case Map.get(observation, "images") do
      %{} = recorded ->
        %{
          depth: Map.get(recorded, "depth"),
          colour: Map.get(recorded, "colour"),
          range: range(Map.get(recorded, "range"))
        }

      nil ->
        drawn(Map.get(observation, "depth"), Map.get(observation, "rgba"))
    end
  end

  defp drawn(nil, nil), do: %{depth: nil, colour: nil, range: nil}

  defp drawn(depth, rgba) do
    %{
      depth: depth && depth |> depth_view() |> elem(0) |> Png.greyscale() |> Base.encode64(),
      colour:
        rgba &&
          rgba
          |> Enum.map(fn row -> Enum.map(row, &colour_byte/1) end)
          |> Png.rgb()
          |> Base.encode64(),
      range: depth && depth |> depth_view() |> elem(1)
    }
  end

  @doc """
  Whether an observation has a picture in it.

  What a replay asks before drawing a frame: a step whose sensor kept nothing
  drawable is not a step with two blank boxes in it.
  """
  @spec pictures?(map()) :: boolean()
  def pictures?(observation) do
    %{depth: depth, colour: colour} = images(observation)
    not is_nil(depth) or not is_nil(colour)
  end

  defp range([low, high]), do: {low * 1.0, high * 1.0}
  defp range(_none), do: nil

  @doc """
  The greyscale rows a depth image becomes, and the range they were drawn over.

  Public because it is the picture's arithmetic rather than its presentation: a
  range that collapsed — everything seen at one depth — has to be visible as such.
  """
  @spec depth_view([[number()]]) :: {[[non_neg_integer()]], {float(), float()} | nil}
  def depth_view(rows) do
    case rows |> List.flatten() |> Enum.reject(&(&1 == 0.0)) do
      [] ->
        {Enum.map(rows, fn row -> Enum.map(row, fn _value -> 0 end) end), nil}

      depths ->
        low = Enum.min(depths)
        high = Enum.max(depths)

        {Enum.map(rows, fn row -> Enum.map(row, &depth_byte(&1, low, high)) end), {low, high}}
    end
  end

  # Nearest is dark, furthest is light: depth reads as a picture of the surface,
  # and a pixel that saw nothing stays black along with it.
  defp depth_byte(depth, _low, _high) when depth == 0.0, do: 0

  defp depth_byte(depth, low, high) when high > low,
    do: round(32 + 223 * (depth - low) / (high - low))

  defp depth_byte(_depth, _low, _high), do: 255

  defp markup(sensor_id, images) do
    case images do
      %{depth: nil, colour: nil} ->
        safe(
          ~s(<p class="px-2 py-6 text-center text-xs text-base-content/50">) <>
            "no image from this sensor</p>"
        )

      %{depth: depth, colour: colour} ->
        safe(
          ~s(<div class="grid grid-cols-2 gap-1">) <>
            image(depth, :depth, sensor_id) <> image(colour, :colour, sensor_id) <> "</div>"
        )
    end
  end

  defp image(nil, _kind, _sensor_id), do: ""

  defp image(base64, kind, sensor_id) do
    ~s(<figure><img src="data:image/png;base64,) <>
      base64 <>
      ~s(" alt="#{escaped(kind)} of #{escaped(sensor_id)}") <>
      ~s( class="w-full rounded-sm bg-base-300 [image-rendering:pixelated]"/></figure>)
  end

  # rgba arrives as four floats from 0 to 1; the fourth is alpha, and a frame of
  # this world is opaque, so it is not carried into the image.
  defp colour_byte([red, green, blue | _alpha]),
    do: [round(red * 255), round(green * 255), round(blue * 255)]

  defp note(step, observation) do
    case images(observation).range do
      nil ->
        if has_picture?(observation),
          do: "step #{step} · saw nothing",
          else: "step #{step} · no image"

      {low, high} when high - low < 0.001 ->
        "step #{step} · flat at #{fixed(low)} m"

      {low, high} ->
        "step #{step} · depth #{fixed(low)}–#{fixed(high)} m"
    end
  end

  defp has_picture?(observation),
    do: Map.has_key?(observation, "depth") or Map.has_key?(observation, "images")

  defp fixed(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  # The only things in a frame that are not numbers of ours, escaped before they
  # become part of the markup.
  defp escaped(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # Markup this module built from escaped parts: the page can interpolate it, and
  # does not have to take this module's word for it by calling `raw`.
  defp safe(markup), do: {:safe, markup}
end
