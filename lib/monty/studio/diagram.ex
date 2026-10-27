defmodule Monty.Studio.Diagram do
  @moduledoc """
  The geometry of an experiment's wiring, computed once so a template only
  draws.

  A setup is a graph of sensors, learning modules and a motor system; a diagram
  is where those go on a canvas. Keeping the arithmetic here rather than in
  HEEx makes the layout testable — "given two sensors and one learning module,
  the module sits between them" is an assertion, not a matter of taste — and it
  keeps the template to a `for` loop over boxes and lines.

  Coordinates are in SVG user units. The columns are fixed width, so a wider
  diagram is a wider canvas rather than a smaller font.
  """

  alias Monty.Studio.Setup

  @node_width 176
  @node_height 40
  @column_gap 88
  @row_gap 12
  @margin 24

  defstruct width: 0, height: 0, nodes: [], edges: []

  @type kind :: :environment | :sensor | :learning_module | :motor

  @type diagram_node :: %{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t() | nil,
          status: atom() | nil,
          x: number(),
          y: number(),
          width: number(),
          height: number()
        }

  @type edge :: %{
          from: String.t(),
          to: String.t(),
          kind: :sensor_input | :hierarchy | :vote | :goal,
          x1: number(),
          y1: number(),
          x2: number(),
          y2: number()
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
    environment = place_environment(environment_node(setup))
    sensors = column(setup.sensors, :sensor, &sensor_node/1)
    learning_modules = column(setup.learning_modules, :learning_module, &learning_module_node/1)
    motor = motor_node(setup)
    linked = MapSet.new(for %{from: {:sensor, id}} <- setup.connections, do: id)
    sensors = Enum.map(sensors, &mark_linked(&1, linked))

    top = column_top(environment)

    tallest =
      [sensors, learning_modules, motor] |> Enum.map(&stack_height/1) |> Enum.max(fn -> 0 end)

    sensors = place(sensors, 0, top, tallest)
    learning_modules = place(learning_modules, 1, top, tallest)
    motor = place(motor, 2, top, tallest)

    nodes = Enum.reject([environment | sensors ++ learning_modules ++ motor], &is_nil/1)

    edges = edges(setup.connections, nodes) ++ goal_edges(setup, nodes)

    %__MODULE__{
      width: width(nodes),
      height: height(nodes),
      nodes: nodes,
      edges: edges
    }
  end

  @doc "The node for an id, if the diagram has one."
  @spec node(t(), String.t()) :: diagram_node() | nil
  def node(%__MODULE__{nodes: nodes}, id), do: Enum.find(nodes, &(&1.id == id))

  @doc "Nodes of one kind, left to right and top to bottom."
  @spec nodes(t(), kind()) :: [diagram_node()]
  def nodes(%__MODULE__{nodes: nodes}, kind), do: Enum.filter(nodes, &(&1.kind == kind))

  defp environment_node(%Setup{environment: nil}), do: nil

  defp environment_node(%Setup{environment: environment}) do
    %{
      id: "environment",
      kind: :environment,
      label: module_label(environment.module, "environment"),
      detail: environment_detail(environment),
      status: environment.module && environment.module.status,
      width: @node_width * 2,
      height: @node_height,
      x: 0,
      y: 0
    }
  end

  defp environment_detail(environment) do
    case environment.objects do
      [] -> environment.interface && environment.interface.class
      objects -> "#{length(objects)} object(s): #{Enum.join(objects, ", ")}"
    end
  end

  defp sensor_node(sensor) do
    %{
      id: sensor.id,
      kind: :sensor,
      label: sensor.id,
      detail: module_label(sensor.module, "sensor module"),
      status: sensor.module && sensor.module.status
    }
  end

  # A sensor that feeds no learning module is not an error — a view finder is
  # there for the motor policies — but it does look like a missing arrow, so it
  # says so on the box instead of leaving the reader to wonder.
  defp mark_linked(node, linked) do
    if MapSet.member?(linked, node.id) do
      Map.put(node, :linked?, true)
    else
      node
      |> Map.put(:linked?, false)
      |> Map.put(:detail, (node.detail || "") <> " · no percept input")
    end
  end

  defp learning_module_node(learning_module) do
    %{
      id: learning_module.id,
      kind: :learning_module,
      label: learning_module.id,
      detail: module_label(learning_module.module, "learning module"),
      status: learning_module.module && learning_module.module.status
    }
  end

  defp motor_node(%Setup{motor_system: nil}), do: []

  defp motor_node(%Setup{motor_system: motor}) do
    [
      %{
        id: "motor_system",
        kind: :motor,
        label: module_label(motor.module, "motor system"),
        detail:
          Enum.map_join(motor.policies, ", ", fn {_name, policy} ->
            module_label(policy, "policy")
          end),
        status: motor.module && motor.module.status,
        width: @node_width,
        height: @node_height
      }
    ]
  end

  defp module_label(nil, fallback), do: fallback
  defp module_label(%{class: nil}, fallback), do: fallback
  defp module_label(%{class: class}, _fallback), do: class

  # A column is stacked, then centred against the tallest column: with two
  # sensors and one learning module the module belongs between them, not level
  # with the first sensor.
  defp column(entries, kind, describe) do
    entries
    |> Enum.map(describe)
    |> Enum.map(fn node ->
      Map.merge(node, %{kind: kind, x: 0, y: 0, width: @node_width, height: @node_height})
    end)
  end

  defp place_environment(nil), do: nil
  defp place_environment(node), do: %{node | x: @margin, y: @margin}

  defp place([], _index, _top, _tallest), do: []

  defp place(nodes, index, top, tallest) do
    start = top + (tallest - stack_height(nodes)) / 2

    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, row} ->
      Map.merge(node, %{
        x: @margin + index * (@node_width + @column_gap),
        y: start + row * (@node_height + @row_gap)
      })
    end)
  end

  defp stack_height([]), do: 0
  defp stack_height(nodes), do: length(nodes) * @node_height + (length(nodes) - 1) * @row_gap

  defp column_top(nil), do: @margin
  defp column_top(%{y: y, height: height}), do: y + height + @column_gap

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
          x2: target.x,
          y2: target.y + target.height / 2
        }
      else
        _missing -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Goals travel the other way: every learning module's goal proposals reach
  # the motor system (through the attention system, which passes them all by
  # default). Leaving that out of the picture makes the motor box look detached.
  defp goal_edges(%Setup{motor_system: nil}, _nodes), do: []

  defp goal_edges(setup, nodes) do
    by_id = Map.new(nodes, &{&1.id, &1})

    case Map.get(by_id, "motor_system") do
      nil ->
        []

      motor ->
        Enum.flat_map(setup.learning_modules, fn learning_module ->
          case Map.get(by_id, learning_module.id) do
            nil ->
              []

            module ->
              [
                %{
                  from: learning_module.id,
                  to: "motor_system",
                  kind: :goal,
                  x1: module.x + module.width,
                  y1: module.y + module.height / 2,
                  x2: motor.x,
                  y2: motor.y + motor.height / 2
                }
              ]
          end
        end)
    end
  end

  defp width([]), do: 0
  defp width(nodes), do: nodes |> Enum.map(&(&1.x + &1.width)) |> Enum.max() |> Kernel.+(@margin)

  defp height([]), do: 0

  defp height(nodes),
    do: nodes |> Enum.map(&(&1.y + &1.height)) |> Enum.max() |> Kernel.+(@margin)
end
