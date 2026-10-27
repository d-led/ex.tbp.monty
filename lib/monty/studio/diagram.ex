defmodule Monty.Studio.Diagram do
  @moduledoc """
  The geometry of an experiment's wiring, computed once so a template only
  draws.

  A setup is a graph of sensors, learning modules and a motor system; a diagram
  is where those go on a canvas. Keeping the arithmetic here rather than in
  HEEx makes the layout testable — "given two sensors and one learning module,
  the module sits between them" is an assertion, not a matter of taste — and it
  keeps the template to a `for` loop over boxes and lines.

  Boxes are sized from the text they hold, in three fixed columns: a label that
  does not fit is a diagram that lies, so a long class name makes a wider box
  rather than an ellipsis. Coordinates are SVG user units, which is why the
  arithmetic is per-character: there is no font metrics here, only a budget.
  """

  alias Monty.Studio.Setup

  @character_width 6.1
  @padding 20
  @min_node_width 176
  @max_node_width 300
  @node_height 42
  @note_height 14
  @column_gap 72
  @row_gap 12
  @environment_gap 42
  @bus_gutter 22
  @margin 24

  defstruct width: 0, height: 0, nodes: [], edges: []

  @type kind :: :environment | :sensor | :learning_module | :motor

  @type diagram_node :: %{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t() | nil,
          note: String.t() | nil,
          status: atom() | nil,
          x: number(),
          y: number(),
          width: number(),
          height: number()
        }

  @type edge :: %{
          from: String.t(),
          to: String.t(),
          kind: :percept | :sensor_input | :hierarchy | :vote | :goal,
          x1: number(),
          y1: number(),
          x2: number(),
          y2: number(),
          via: [{number(), number()}]
        }

  @type t :: %__MODULE__{
          width: number(),
          height: number(),
          nodes: [diagram_node()],
          edges: [edge()]
        }

  @doc "Lays out an experiment: environment on top, sensors, modules, motor."
  @spec new(Setup.t()) :: t()
  def new(%Setup{} = setup) do
    linked = MapSet.new(for %{from: {:sensor, id}} <- setup.connections, do: id)

    sensors = setup.sensors |> Enum.map(&sensor_node(&1, linked)) |> column(:sensor)

    learning_modules =
      setup.learning_modules |> Enum.map(&learning_module_node/1) |> column(:learning_module)

    motor = setup |> motor_nodes() |> column(:motor)

    # The world is the thing being looked at, so it belongs over the sensors
    # that look at it rather than in the top-left corner of an empty shelf.
    top = @margin + @node_height + @environment_gap
    columns = [sensors, learning_modules, motor]
    tallest = columns |> Enum.map(&stack_height/1) |> Enum.max(fn -> 0 end)
    positioned = place_columns(columns, top, tallest)

    environment =
      setup |> environment_node() |> place_environment(@margin, column_width(sensors))

    nodes = Enum.reject([environment | List.flatten(positioned)], &is_nil/1)

    %__MODULE__{
      width: extent(nodes, &(&1.x + &1.width)),
      height: extent(nodes, &(&1.y + &1.height)),
      nodes: nodes,
      edges:
        edges(setup.connections, nodes) ++
          percept_edges(setup, nodes) ++ goal_edges(setup, nodes)
    }
  end

  @doc "The node for an id, if the diagram has one."
  @spec node(t(), String.t()) :: diagram_node() | nil
  def node(%__MODULE__{nodes: nodes}, id), do: Enum.find(nodes, &(&1.id == id))

  @doc "Nodes of one kind, left to right and top to bottom."
  @spec nodes(t(), kind()) :: [diagram_node()]
  def nodes(%__MODULE__{nodes: nodes}, kind), do: Enum.filter(nodes, &(&1.kind == kind))

  # -- what the boxes say ----------------------------------------------------

  defp environment_node(%Setup{environment: nil}), do: nil

  defp environment_node(%Setup{environment: environment}) do
    %{
      id: "environment",
      kind: :environment,
      label: module_label(environment.module, "environment"),
      detail: environment_detail(environment),
      note: nil,
      status: environment.module && environment.module.status
    }
  end

  defp environment_detail(environment) do
    case environment.objects do
      [] -> environment.interface && environment.interface.class
      objects -> "#{length(objects)} object(s): #{Enum.join(objects, ", ")}"
    end
  end

  defp sensor_node(sensor, linked) do
    %{
      id: sensor.id,
      kind: :sensor,
      label: sensor.id,
      detail: module_label(sensor.module, "sensor module"),
      # A sensor that feeds no learning module is not an error — a view finder
      # is there to record a wide shot, not to be matched — but it must not
      # look like a missing arrow, so the box says so where it cannot be
      # truncated away.
      note: if(MapSet.member?(linked, sensor.id), do: nil, else: "no percept input"),
      status: sensor.module && sensor.module.status
    }
  end

  defp learning_module_node(learning_module) do
    %{
      id: learning_module.id,
      kind: :learning_module,
      label: learning_module.id,
      detail: module_label(learning_module.module, "learning module"),
      note: nil,
      status: learning_module.module && learning_module.module.status
    }
  end

  defp motor_nodes(%Setup{motor_system: nil}), do: []

  defp motor_nodes(%Setup{motor_system: motor}) do
    [
      %{
        id: "motor_system",
        kind: :motor,
        label: module_label(motor.module, "motor system"),
        detail:
          Enum.map_join(motor.policies, ", ", fn {_name, policy} ->
            module_label(policy, "policy")
          end),
        note: nil,
        status: motor.module && motor.module.status
      }
    ]
  end

  defp module_label(nil, fallback), do: fallback
  defp module_label(%{class: nil}, fallback), do: fallback
  defp module_label(%{class: class}, _fallback), do: class

  # -- geometry --------------------------------------------------------------

  defp column(nodes, kind) do
    width = column_width(nodes)
    height = if Enum.any?(nodes, & &1.note), do: @node_height + @note_height, else: @node_height

    Enum.map(nodes, &Map.merge(&1, %{kind: kind, width: width, height: height, x: 0, y: 0}))
  end

  # One width per column, from the widest label in it: two sensors in a column
  # that disagree about their size is noise, not information.
  defp column_width(nodes) do
    nodes
    |> Enum.flat_map(fn node -> [node.label, node.detail, node.note] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&text_width/1)
    |> Enum.max(fn -> 0 end)
    |> max(@min_node_width)
    |> min(@max_node_width)
  end

  defp text_width(text), do: round(String.length(text) * @character_width) + @padding

  defp place_environment(nil, _column_x, _column_width), do: nil

  # The world spans its sensors and a gutter to their left, where the percept
  # bus runs: one arrow per sensor, none of them crossing a box.
  defp place_environment(node, column_x, column_width) do
    Map.merge(node, %{
      x: column_x,
      y: @margin,
      width: column_width + @bus_gutter,
      height: @node_height
    })
  end

  # Columns are placed left to right, each after the width of the one before it,
  # and centred against the tallest column: with two sensors and one learning
  # module, the module belongs between them.
  defp place_columns(columns, top, tallest) do
    columns
    |> Enum.reduce({[], @margin + @bus_gutter}, fn nodes, {placed, x} ->
      start = top + (tallest - stack_height(nodes)) / 2
      width = nodes |> Enum.map(& &1.width) |> Enum.max(fn -> 0 end)

      positioned =
        nodes
        |> Enum.with_index()
        |> Enum.map(fn {node, row} ->
          %{node | x: x, y: start + row * (node.height + @row_gap)}
        end)

      {placed ++ [positioned], x + width + @column_gap}
    end)
    |> elem(0)
  end

  defp stack_height([]), do: 0

  defp stack_height(nodes) do
    Enum.reduce(nodes, 0, fn node, total -> total + node.height end) +
      (length(nodes) - 1) * @row_gap
  end

  defp extent([], _position), do: 0

  defp extent(nodes, position),
    do: nodes |> Enum.map(position) |> Enum.max() |> Kernel.+(Float.ceil(@margin / 4))

  # -- edges -----------------------------------------------------------------

  defp edges(connections, nodes) do
    by_id = Map.new(nodes, &{&1.id, &1})

    connections
    |> Enum.map(fn %{from: {_from_kind, from}, to: {_to_kind, to}, kind: kind} ->
      with %{} = source <- Map.get(by_id, from),
           %{} = target <- Map.get(by_id, to) do
        %{
          from: from,
          to: to,
          kind: kind,
          x1: source.x + source.width,
          y1: source.y + source.height / 2,
          via: [],
          x2: target.x,
          y2: target.y + target.height / 2
        }
      else
        _missing -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # The world is what the sensors look at: a trunk down the gutter, and a
  # branch into each sensor, so an arrow never runs through a box.
  defp percept_edges(%Setup{environment: nil}, _nodes), do: []

  defp percept_edges(_setup, nodes) do
    case Enum.find(nodes, &(&1.kind == :environment)) do
      nil -> []
      environment -> Enum.flat_map(nodes, &percept_edge(environment, &1))
    end
  end

  defp percept_edge(_environment, %{kind: kind}) when kind != :sensor, do: []

  defp percept_edge(environment, sensor) do
    trunk_x = @margin + @bus_gutter / 2
    middle = sensor.y + sensor.height / 2

    [
      %{
        from: environment.id,
        to: sensor.id,
        kind: :percept,
        x1: trunk_x,
        y1: environment.y + environment.height,
        via: [{trunk_x, middle}],
        x2: sensor.x,
        y2: middle
      }
    ]
  end

  # Goals travel the other way: every learning module's goal proposals reach the
  # motor system, through the attention system, which passes them all by
  # default. Without it the motor box looks detached.
  defp goal_edges(%Setup{motor_system: nil}, _nodes), do: []

  defp goal_edges(setup, nodes) do
    by_id = Map.new(nodes, &{&1.id, &1})

    case Map.get(by_id, "motor_system") do
      nil -> []
      motor -> Enum.flat_map(setup.learning_modules, &goal_edge(Map.get(by_id, &1.id), motor))
    end
  end

  defp goal_edge(nil, _motor), do: []

  defp goal_edge(module, motor) do
    [
      %{
        from: module.id,
        to: "motor_system",
        kind: :goal,
        x1: module.x + module.width,
        y1: module.y + module.height / 2,
        via: [],
        x2: motor.x,
        y2: motor.y + motor.height / 2
      }
    ]
  end
end
