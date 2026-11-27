defmodule Monty.Simulators.ExMujoco.SimulatorTest do
  @moduledoc """
  Translations of Monty's `tests/unit/simulators/mujoco/mujoco_simulator_test.py`.

  Monty's cases drive `MuJoCoSimulator`'s **spec** (`sim.spec.geom(name)`,
  `sim.spec.mesh(name)`) and count what it recompiles (`sim.model.ngeom`). This
  port has no spec: a scene is MJCF text that `ex_mujoco` compiles, so a case
  here drives `Scene.build/1` — the text, and the objects it says it placed —
  and `ExMujoco.load_string/1` where the compiled model is what Monty read.

  Two shapes of case have no entry point to drive, and are listed here rather
  than translated:

  - `test_remove_all_objects` and `test_adding_custom_objects_after_removing_all`
    remove objects from a scene and add them back. A scene here is built once
    from a config, so nothing removes an object from it; "the scene without that
    object" is the same case as "a scene built without it".
  - `test_agent_that_does_not_understand_an_action`, its `_raises` sibling and
    `test_agent_action_with_attribute_error` drive `actuate` on a live world with
    a mock agent; `test_renderer_for_res_returns_different_renderers` and
    `test_renderer_for_res_returns_same_renderer` need a GL context. Both groups
    are the compiled world's `Monty.Simulators.ExMujoco.World` and `Simulator`,
    and are not driven from this file yet.

  Monty's refusals are classes (`UnknownObjectType`, `MissingObjectTexture`, …).
  This port raises `ArgumentError` with a message that names the object or the
  file that is missing, and a case asserts on that name: the refusal, not the
  class, is what a caller here can act on.
  """
  use ExUnit.Case, async: true

  alias Monty.Simulators.ExMujoco.Scene

  # Monty's own `tests/unit/resources/test_custom_objects`: a reference pose of
  # `[1, 1, 1]` turned a quarter turn about x, and the same pose with a scale of
  # three — plus the three shapes of a refusal.
  @reference_pose ~s({"refpos": [1.0, 1.0, 1.0], "refquat": [0.7071067811865475, 0.7071067811865475, 0.0, 0.0]})

  @scaled_pose ~s({"refpos": [1.0, 1.0, 1.0], "refquat": [0.7071067811865475, 0.7071067811865475, 0.0, 0.0], "scale": [3.0, 3.0, 3.0]})

  setup do
    root =
      Path.join(System.tmp_dir!(), "ex_mujoco_simulator_#{System.unique_integer([:positive])}")

    object!(root, "valid_object", @reference_pose)
    object!(root, "scaled_object", @scaled_pose)
    object!(root, "missing_metadata")
    object!(root, "missing_texture", @reference_pose, files: [:model])
    object!(root, "missing_model", @reference_pose, files: [:texture])

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  describe "the scene" do
    # test_initial_scene_is_empty
    test "with no objects has no geom in it" do
      # Monty reads `sim.model.ngeom == 0` and `len(sim.spec.geoms) == 0`. A
      # compiled model's geom count is not on this port's public surface — the
      # text is — so the case reads what the scene says about geoms.
      %{xml: xml, objects: objects} = Scene.build(%{"agents" => []})

      assert objects == []
      refute xml =~ "<geom"
    end

    # test_add_primitive_object, which Monty parametrizes over `PRIMITIVE_OBJECTS`:
    # the same five, walked in one case.
    test "gives every primitive MuJoCo's own type, named for what it is" do
      primitives = ["box", "capsule", "cylinder", "ellipsoid", "sphere"]

      for name <- primitives do
        %{xml: xml, objects: [object]} =
          Scene.build(%{"agents" => [], "objects" => [%{"name" => name}]})

        assert object.geom == "#{name}_0"
        assert xml =~ ~s(<geom name="#{name}_0" type="#{name}")
      end
    end

    # test_multiple_objects_have_different_ids
    test "numbers objects in the order they were added" do
      %{xml: xml, objects: objects} = Scene.build(%{"objects" => named(["box", "box", "box"])})

      assert Enum.map(objects, & &1.geom) == ["box_0", "box_1", "box_2"]
      assert xml =~ ~s(<geom name="box_2")
    end

    # test_primitive_object_positioning
    test "puts a primitive where the experiment says" do
      %{xml: xml, objects: [object]} =
        Scene.build(%{
          "objects" => [%{"name" => "box", "position" => [1.0, 1.0, 2.0]}]
        })

      assert object.position == [1.0, 1.0, 2.0]
      assert xml =~ ~s(pos="1.0 1.0 2.0")
    end

    # test_primitive_box_scaling
    test "scales a box by the size it is given" do
      %{xml: xml, objects: [object]} =
        Scene.build(%{"objects" => [%{"name" => "box", "scale" => [3.0, 3.0, 3.0]}]})

      assert object.shape.size == [3.0, 3.0, 3.0]
      assert xml =~ ~s(size="3.0 3.0 3.0")
    end

    # test_primitive_sphere_scaling
    test "scales a sphere by the size it is given" do
      %{xml: xml} =
        Scene.build(%{"objects" => [%{"name" => "sphere", "scale" => [3.0, 3.0, 3.0]}]})

      assert xml =~ ~s(<geom name="sphere_0" type="sphere" size="3.0 3.0 3.0")
    end
  end

  describe "a custom object" do
    # test_custom_object_adding
    test "is a mesh with the reference pose its metadata states", %{root: root} do
      %{xml: xml, objects: [object]} =
        Scene.build(%{"data_path" => root, "objects" => [%{"name" => "valid_object"}]})

      assert xml =~ ~s(<geom name="valid_object_0" type="mesh")
      assert xml =~ ~s(refpos="1.0 1.0 1.0")
      assert xml =~ ~s(refquat="0.7071067811865475 0.7071067811865475 0.0 0.0")
      assert object.shape.mesh == "valid_object_1.0_1.0_1.0_mesh"
    end

    # test_custom_object_scaling_in_call
    test "is scaled by the scale it is asked for", %{root: root} do
      %{xml: xml} =
        Scene.build(%{
          "data_path" => root,
          "objects" => [%{"name" => "valid_object", "scale" => [2.0, 2.0, 2.0]}]
        })

      assert xml =~ ~s(mesh="valid_object_2.0_2.0_2.0_mesh")
      assert xml =~ ~s(scale="2.0 2.0 2.0")
    end

    # test_custom_object_scaling_from_metadata
    test "is scaled by the scale its metadata states, which its mesh is not named for", %{
      root: root
    } do
      %{xml: xml} =
        Scene.build(%{"data_path" => root, "objects" => [%{"name" => "scaled_object"}]})

      # The name carries the scale that was asked for, the mesh carries the
      # product: a metadata scale of three and no argument is three, named one.
      assert xml =~ ~s(mesh="scaled_object_1.0_1.0_1.0_mesh")
      assert xml =~ ~s(scale="3.0 3.0 3.0")
    end

    # test_custom_object_scaling_with_both: Monty draws the scale with Hypothesis;
    # this is the same rule on fixed scales (the port's generators are seeded
    # fixtures).
    test "asked for a scale and stated a scale is the product of the two", %{root: root} do
      for {requested, product} <- [
            {[0.5, 1.5, 2.0], "1.5 4.5 6.0"},
            {[2.0, 2.0, 2.0], "6.0 6.0 6.0"}
          ] do
        %{xml: xml} =
          Scene.build(%{
            "data_path" => root,
            "objects" => [%{"name" => "scaled_object", "scale" => requested}]
          })

        assert xml =~ ~s(mesh="scaled_object_#{Enum.map_join(requested, "_", &number/1)}_mesh")
        assert xml =~ ~s(scale="#{product}")
      end
    end

    # test_duplicate_custom_objects_share_meshes
    test "that stands in the scene twice is one mesh, listed once", %{root: root} do
      %{xml: xml, objects: objects} =
        Scene.build(%{
          "data_path" => root,
          "objects" => named(["valid_object", "valid_object"])
        })

      assert Enum.map(objects, & &1.geom) == ["valid_object_0", "valid_object_1"]

      # A mesh, a texture and a material are declared once — MuJoCo refuses a
      # second declaration of the same name.
      assert xml |> String.split(~s(<mesh name="valid_object_1.0_1.0_1.0_mesh")) |> length() == 2

      assert xml |> String.split(~s(<texture name="valid_object_1.0_1.0_1.0_tex")) |> length() ==
               2
    end

    # test_duplicate_custom_objects_different_scales
    test "at two scales is two meshes, because MuJoCo keeps the scale on the mesh", %{root: root} do
      %{xml: xml} =
        Scene.build(%{
          "data_path" => root,
          "objects" => [
            %{"name" => "valid_object"},
            %{"name" => "valid_object", "scale" => [2.0, 2.0, 2.0]}
          ]
        })

      assert xml =~ ~s(mesh="valid_object_1.0_1.0_1.0_mesh")
      assert xml =~ ~s(mesh="valid_object_2.0_2.0_2.0_mesh")
    end

    # test_custom_object_with_no_data_path
    test "with no dataset to read is refused rather than guessed at" do
      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{"objects" => [%{"name" => "valid_object"}]})
        end

      assert error.message =~ "data path"
    end

    # test_custom_object_missing
    test "that is not in the dataset is refused by name", %{root: root} do
      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{"data_path" => root, "objects" => [%{"name" => "invalid_object"}]})
        end

      assert error.message =~ "invalid_object"
    end

    # test_custom_object_missing_texture
    test "with no texture is refused by the file it is missing", %{root: root} do
      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{"data_path" => root, "objects" => [%{"name" => "missing_texture"}]})
        end

      assert error.message =~ "texture_map.png"
    end

    # test_custom_object_missing_model
    test "with no model is refused by the file it is missing", %{root: root} do
      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{"data_path" => root, "objects" => [%{"name" => "missing_model"}]})
        end

      assert error.message =~ "textured.obj"
    end

    # test_custom_object_missing_metadata
    test "with no metadata is measured from its own origin, unturned and unscaled", %{root: root} do
      %{xml: xml} =
        Scene.build(%{"data_path" => root, "objects" => [%{"name" => "missing_metadata"}]})

      assert xml =~ ~s(refpos="0.0 0.0 0.0")
      assert xml =~ ~s(refquat="1.0 0.0 0.0 0.0")
      assert xml =~ ~s(scale="1.0 1.0 1.0")
    end
  end

  # Objects as the scene's `"objects"` list takes them: a name and nothing else.
  defp named(names), do: Enum.map(names, &%{"name" => &1})

  defp object!(root, name, metadata \\ nil, options \\ []) do
    files = Keyword.get(options, :files, [:model, :texture])
    path = Path.join(root, name)
    File.mkdir_p!(path)

    if :model in files, do: File.write!(Path.join(path, "textured.obj"), "# a triangle\n")
    if :texture in files, do: File.write!(Path.join(path, "texture_map.png"), <<137, 80, 78, 71>>)
    if metadata, do: File.write!(Path.join(path, "metadata.json"), metadata)

    path
  end

  # A float as the scene writes it: the shortest form that reads back the same.
  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
end
