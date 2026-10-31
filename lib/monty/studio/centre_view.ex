defmodule Monty.Studio.CentreView do
  @moduledoc """
  The object, in the middle of a frame, with the agent that is looking at it.

  A run streams one picture per sensor per step, and each of those is what a
  camera saw. Nothing showed the thing the experiment is *about*: how far the
  agent is from the object, and whether the object is in reach. That is a picture
  nobody can infer from a patch, and it is the first question asked when a run
  reports nothing: is the agent even there?

  So this is a diagram rather than a render. The sphere is drawn where it is, at
  the size the world gave it; the agent and its sensors are drawn where they are;
  and the frame is scaled so that both fit, with the object at the centre. It is
  a projection along the plane that holds the agent and the object, because that
  is the plane the one interesting distance lies in.

  The numbers come from the world the run is stepping — `scene`, `world.agent` and
  `world.sensors` — so the picture cannot disagree with the run. A world with no
  scene has nothing to centre on, and answers `nil` rather than an empty box.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Simulators.Synthetic.Environment
  alias Monty.Simulators.Synthetic.Kinematics

  @width 320
  @height 320
  @margin 24

  # Two directions this close to parallel have no usable cross product: the
  # agent stands on the world's up axis and the plane has to be picked another
  # way.
  @parallel 0.5

  @type point :: %{required(:x) => float(), required(:y) => float()}
  @type sensor :: %{required(:id) => String.t(), required(:x) => float(), required(:y) => float()}

  @type t :: %{
          required(:step) => non_neg_integer(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:object) => %{
            required(:x) => float(),
            required(:y) => float(),
            required(:radius) => float()
          },
          required(:agent) => point(),
          required(:sensors) => [sensor()],
          required(:note) => String.t(),
          required(:media_type) => String.t(),
          required(:data) => {:safe, iodata()}
        }

  @doc """
  The view of one step of `world`, or `nil` when it has no scene to centre on.

  `:step` is drawn into the frame as well as returned, so a picture that arrives
  out of order is recognisable as such.
  """
  @spec frame(term(), non_neg_integer()) :: t() | nil
  def frame(%Environment{scene: nil}, _step), do: nil

  def frame(%Environment{scene: scene, world: world}, step) do
    view(scene, world.agent, Kinematics.sensor_world_poses(world), step)
  end

  def frame(_world_without_a_scene, _step), do: nil

  defp view(scene, agent, sensors, step) do
    centre = scene.centre
    gap = distance(agent.position, centre)
    {right, towards} = axes(agent.position, centre)

    # The scale has to fit everything drawn, which is not the same as fitting the
    # agent: a view finder sits three centimetres *behind* the patch, and scaling
    # to the agent alone drew it outside the picture at the one gap where the
    # surface agent actually stands.
    extent =
      [
        scene.radius,
        gap | Enum.map(sensors, fn {_id, sensor} -> distance(sensor.position, centre) end)
      ]
      |> Enum.max()

    scale = (min(@width, @height) / 2 - @margin) / extent

    project = fn position ->
      offset = SpatialArithmetics.subtract(position, centre)

      %{
        x: @width / 2 + dot(offset, right) * scale,
        y: @height / 2 - dot(offset, towards) * scale
      }
    end

    object = Map.merge(project.(centre), %{radius: scene.radius * scale})
    agent_point = project.(agent.position)

    sensors =
      for {sensor_id, sensor} <- Enum.sort(sensors) do
        Map.merge(project.(sensor.position), %{id: sensor_id})
      end

    %{
      step: step,
      width: @width,
      height: @height,
      object: object,
      agent: agent_point,
      sensors: sensors,
      note: note(surface_distance(gap, scene.radius)),
      media_type: "image/svg+xml",
      data: svg(step, object, agent_point, sensors)
    }
  end

  # The plane the picture is drawn in: it holds the agent and the object, so the
  # distance the run cares about is drawn at its true length, and the other axis
  # is horizontal in the world.
  defp axes(position, centre) do
    towards = unit(SpatialArithmetics.subtract(position, centre), [0.0, 1.0, 0.0])
    right = SpatialArithmetics.cross([0.0, 1.0, 0.0], towards)

    right =
      if SpatialArithmetics.magnitude(right) < @parallel,
        do: SpatialArithmetics.cross([1.0, 0.0, 0.0], towards),
        else: right

    {unit(right, [1.0, 0.0, 0.0]), towards}
  end

  defp surface_distance(gap, radius), do: max(gap - radius, 0.0)

  defp note(distance), do: "agent #{fixed(distance)} m from the surface"

  defp svg(step, object, agent, sensors) do
    sensor_markup =
      Enum.map(sensors, fn sensor ->
        """
        <circle cx="#{px(sensor.x)}" cy="#{px(sensor.y)}" r="3" fill="currentColor" opacity="0.5"/>\
        """
      end)

    safe("""
    <svg viewBox="0 0 #{@width} #{@height}" role="img" \
    aria-label="the object and the agent at step #{step}" class="w-full">\
    <line x1="0" y1="#{@height / 2}" x2="#{@width}" y2="#{@height / 2}" stroke="currentColor" \
    stroke-opacity="0.12" stroke-dasharray="3 3"/>\
    <line x1="#{@width / 2}" y1="0" x2="#{@width / 2}" y2="#{@height}" stroke="currentColor" \
    stroke-opacity="0.12" stroke-dasharray="3 3"/>\
    <line x1="#{px(agent.x)}" y1="#{px(agent.y)}" x2="#{px(object.x)}" y2="#{px(object.y)}" \
    stroke="currentColor" stroke-opacity="0.35" stroke-dasharray="4 3"/>\
    <circle cx="#{px(object.x)}" cy="#{px(object.y)}" r="#{px(object.radius)}" fill="currentColor" \
    opacity="0.18" stroke="currentColor" stroke-opacity="0.6"/>\
    #{sensor_markup}\
    <circle cx="#{px(agent.x)}" cy="#{px(agent.y)}" r="4" fill="currentColor" opacity="0.8"/>\
    </svg>
    """)
  end

  # A number of ours, written so that a test can read the note and a reader can
  # compare two steps by eye.
  defp fixed(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  # Geometry arrives as numbers; a viewBox wants them short and finite.
  defp px(value), do: value |> Kernel.*(1.0) |> Float.round(2)

  defp unit(vector, fallback) do
    case SpatialArithmetics.magnitude(vector) do
      length when length > 0.0 -> SpatialArithmetics.normalize(vector)
      _no_direction -> fallback
    end
  end

  defp dot(a, b), do: SpatialArithmetics.dot(a, b)

  defp distance(a, b), do: SpatialArithmetics.magnitude(SpatialArithmetics.subtract(a, b))

  # Markup this module built from escaped parts: the page can interpolate it, and
  # does not have to take this module's word for it by calling `raw`.
  defp safe(markup), do: {:safe, markup}
end
