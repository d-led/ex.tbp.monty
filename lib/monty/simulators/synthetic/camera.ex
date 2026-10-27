defmodule Monty.Simulators.Synthetic.Camera do
  @moduledoc """
  A camera view of the synthetic world, for the page to show while a run happens.

  Monty's real sensor modules hand back RGBA and depth arrays, which a dashboard
  turns into images — base64 PNGs, in the PyView prototype that came before
  this. Nothing here is a photograph: until the MuJoCo bridge exists, the
  synthetic world is a point moving along +x, so its "camera" is a drawing.

  Drawing it as SVG rather than a bitmap is a deliberate trade. It needs no
  image library, it is a string a test can assert on, and it stays sharp at any
  size. When real frames arrive, this module is the only thing that changes: it
  returns `%{media_type: "image/png", data: base64}` instead, and the page keeps
  rendering whatever it is given.
  """

  @width 160
  @height 90

  @type frame :: %{
          sensor_id: String.t(),
          step: non_neg_integer(),
          media_type: String.t(),
          data: String.t(),
          location: [float()],
          note: String.t()
        }

  @doc """
  The view from one sensor at one step.

  The observation is the environment's own — `"location"` in metres relative to
  the agent — so the picture moves when the percept moves, and a test can check
  exactly where the object is drawn.
  """
  @spec frame(String.t(), map(), non_neg_integer()) :: frame()
  def frame(sensor_id, observation, step) do
    location = Map.get(observation, "location", [0.0, 0.0, 0.0])
    {x, y} = project(location)

    %{
      sensor_id: sensor_id,
      step: step,
      media_type: "image/svg+xml",
      data: svg(x, y, step, sensor_id),
      location: location,
      note: "step #{step} · x #{format(Enum.at(location, 0))} m"
    }
  end

  @doc "Where a world location lands in the viewport."
  @spec project([number()]) :: {float(), float()}
  def project([x, y | _rest]) do
    # Metres are mapped to the viewport around the camera's optical axis, the
    # way a pinhole camera maps the world: one metre to the whole width, with
    # the axis in the middle.
    {clamp(@width / 2 + x * @width, @width), clamp(@height / 2 - y * @height, @height)}
  end

  def project(_not_a_location), do: {@width / 2, @height / 2}

  @doc "The viewport, so a page can size its panel."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  defp svg(x, y, step, sensor_id) do
    """
    <svg viewBox="0 0 #{@width} #{@height}" role="img" \
    aria-label="sensor #{sensor_id} at step #{step}" class="w-full">\
    <rect x="0" y="0" width="#{@width}" height="#{@height}" fill="currentColor" opacity="0.04"/>\
    <line x1="0" y1="#{@height / 2}" x2="#{@width}" y2="#{@height / 2}" stroke="currentColor" stroke-opacity="0.15" stroke-dasharray="3 3"/>\
    <line x1="#{@width / 2}" y1="0" x2="#{@width / 2}" y2="#{@height}" stroke="currentColor" stroke-opacity="0.15" stroke-dasharray="3 3"/>\
    <circle cx="#{x}" cy="#{y}" r="5" fill="currentColor" opacity="0.75"/>\
    </svg>
    """
  end

  defp clamp(value, bound) do
    value |> max(0) |> min(bound) |> Kernel.*(1.0) |> Float.round(2)
  end

  defp format(nil), do: "—"
  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
