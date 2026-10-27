defmodule Monty.Studio.DiagramTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.{Diagram, Setup}

  defp setup_for(name), do: elem(Setup.from_experiment(name), 1)

  describe "the layout of an experiment" do
    test "sensors are on the left, learning modules in the middle, the motor on the right" do
      diagram = Diagram.new(setup_for("tutorial/first_experiment"))

      sensor_x = diagram |> Diagram.nodes(:sensor) |> Enum.map(& &1.x) |> Enum.uniq()
      module_x = diagram |> Diagram.nodes(:learning_module) |> Enum.map(& &1.x) |> Enum.uniq()
      motor_x = diagram |> Diagram.nodes(:motor) |> Enum.map(& &1.x) |> Enum.uniq()

      assert length(sensor_x) == 1
      assert length(module_x) == 1
      assert length(motor_x) == 1
      assert sensor_x |> hd() < module_x |> hd()
      assert module_x |> hd() < motor_x |> hd()
    end

    test "one learning module sits between two sensors, not level with the first" do
      diagram = Diagram.new(setup_for("tutorial/first_experiment"))

      sensors = diagram |> Diagram.nodes(:sensor) |> Enum.map(& &1.y) |> Enum.sort()
      [module] = Diagram.nodes(diagram, :learning_module)

      assert sensors |> hd() < module.y
      assert module.y < sensors |> List.last()
    end

    test "the world is drawn above the sensors" do
      diagram = Diagram.new(setup_for("tutorial/first_experiment"))

      [environment] = Diagram.nodes(diagram, :environment)
      sensor_top = diagram |> Diagram.nodes(:sensor) |> Enum.map(& &1.y) |> Enum.min()

      assert environment.y < sensor_top
    end

    test "the canvas is big enough for everything on it" do
      diagram = Diagram.new(setup_for("randrot_noise_10distinctobj_5lms_dist_agent"))

      right = diagram.nodes |> Enum.map(&(&1.x + &1.width)) |> Enum.max()
      bottom = diagram.nodes |> Enum.map(&(&1.y + &1.height)) |> Enum.max()

      assert diagram.width >= right
      assert diagram.height >= bottom
    end
  end

  describe "the wiring" do
    test "a sensor input is a line from the sensor to the module it feeds" do
      diagram = Diagram.new(setup_for("tutorial/first_experiment"))

      edge = Enum.find(diagram.edges, &(&1.kind == :sensor_input))
      patch = Diagram.node(diagram, "patch")
      module = Diagram.node(diagram, "learning_module_0")

      assert edge.from == "patch"
      assert edge.to == "learning_module_0"
      assert edge.x1 == patch.x + patch.width
      assert edge.y1 == patch.y + patch.height / 2
      assert edge.x2 == module.x
    end

    test "votes are their own lines, because a vote is not input" do
      diagram = Diagram.new(setup_for("randrot_noise_10distinctobj_5lms_dist_agent"))
      kinds = diagram.edges |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

      assert kinds == [:goal, :sensor_input, :vote]
    end

    test "every learning module has a goal arrow into the motor system" do
      diagram = Diagram.new(setup_for("randrot_noise_10distinctobj_5lms_dist_agent"))

      goals = Enum.filter(diagram.edges, &(&1.kind == :goal))

      assert length(goals) == 5
      assert Enum.all?(goals, &(&1.to == "motor_system"))

      assert goals |> Enum.map(& &1.from) |> Enum.sort() ==
               Enum.map(1..5, &"learning_module_#{&1 - 1}") |> Enum.sort()
    end
  end

  describe "what a box says" do
    test "a sensor box is labelled with its id and the class behind it" do
      diagram = Diagram.new(setup_for("tutorial/first_experiment"))
      patch = Diagram.node(diagram, "patch")

      assert patch.label == "patch"
      assert patch.detail == "CameraSM"
      assert patch.status == :planned
    end

    test "a sensor with nothing to learn from says so, instead of looking broken" do
      diagram = Diagram.new(setup_for("tutorial/first_experiment"))
      view_finder = Diagram.node(diagram, "view_finder")

      assert view_finder.linked? == false
      assert view_finder.detail =~ "no percept input"
      assert Diagram.node(diagram, "patch").linked? == true
    end
  end
end
