defmodule Monty.Simulators.ExMujoco.SceneTest do
  use ExUnit.Case, async: true

  alias Monty.Simulators.ExMujoco.Scene

  # A mesh object's directory, as a dataset lays one out: the model, its texture
  # and — sometimes — the metadata that says where its vertices are measured from.
  # What is in the files does not matter here: a scene is text until MuJoCo
  # compiles it, and this is about the text.
  setup do
    root = Path.join(System.tmp_dir!(), "ex_mujoco_scene_#{System.unique_integer([:positive])}")
    object = Path.join(root, "a_part")
    File.mkdir_p!(object)
    File.write!(Path.join(object, "textured.obj"), "# a triangle\n")
    File.write!(Path.join(object, "texture_map.png"), <<137, 80, 78, 71>>)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, object: object}
  end

  defp agents do
    [
      %{
        "agent_id" => "agent_id_0",
        "class" => "SurfaceAgent",
        "position" => [0.0, 1.5, 0.1],
        "rotation" => [1.0, 0.0, 0.0, 0.0],
        "sensor_configs" => %{
          "patch" => %{
            "height" => 64,
            "width" => 64,
            "zoom" => 1.0,
            "position" => [0.0, 0.0, 0.0],
            "rotation" => [1.0, 0.0, 0.0, 0.0],
            "semantic" => true
          },
          "view_finder" => %{
            "height" => 32,
            "width" => 48,
            "zoom" => 1.0,
            "position" => [0.0, 0.0, 0.03],
            "rotation" => [1.0, 0.0, 0.0, 0.0]
          }
        }
      }
    ]
  end

  describe "the scene's own numbers" do
    test "gravity is off: nothing here falls, a step is kinematics" do
      %{xml: xml} = Scene.build(%{"agents" => agents()})

      assert xml =~ ~s(<option gravity="0 0 0"/>)
    end

    test "the offscreen buffer is as large as the largest sensor" do
      %{xml: xml} = Scene.build(%{"agents" => agents()})

      assert xml =~ ~s(offwidth="64")
      assert xml =~ ~s(offheight="64")
    end

    test "a scene with no sensor still has a buffer to render into" do
      %{xml: xml} = Scene.build(%{"agents" => []})

      assert xml =~ ~s(offwidth="64")
    end
  end

  describe "an agent" do
    test "is a body with a free joint, and a hinged head with a camera per sensor" do
      %{xml: xml} = Scene.build(%{"agents" => agents()})

      assert xml =~ ~s(<body name="agent_id_0" pos="0.0 1.5 0.1")
      assert xml =~ ~s(<freejoint name="agent_id_0.free"/>)
      assert xml =~ ~s(<body name="agent_id_0.sensor")
      assert xml =~ ~s(<joint name="agent_id_0.pitch" type="hinge" axis="1 0 0"/>)
      assert xml =~ ~s(<camera name="agent_id_0.patch")
      assert xml =~ ~s(<camera name="agent_id_0.view_finder")
    end

    test "a camera is aimed by its sensor's place on the agent" do
      %{xml: xml} = Scene.build(%{"agents" => agents()})

      assert xml =~ ~s(<camera name="agent_id_0.view_finder" pos="0.0 0.0 0.03")
    end

    test "its inertial is stated where MuJoCo puts an unset one: at the body's own place" do
      # Monty's `add_body(mass: …, inertia: …)` leaves the inertial's position
      # unset, and MuJoCo compiles an unset one as the body's own `pos` — so the
      # agent above has its centre of mass at (0, 3.0, 0.2) in the world, and
      # the scene's `stat.extent`, and the far plane of its depth images, are
      # computed from that. An MJCF file has no way to say "unset" (the
      # attribute is required), so the same number is written out: stating the
      # origin instead halves the far plane and changes every depth image.
      %{xml: xml} = Scene.build(%{"agents" => agents()})

      assert xml =~
               ~s(<inertial pos="0.0 1.5 0.1" quat="1.0 0.0 0.0 0.0" mass="1" diaginertia="1 1 1"/>)
    end
  end

  describe "the field of view" do
    test "is horizontal for Monty and vertical for MuJoCo, and the two agree at one" do
      assert_in_delta Scene.zoom_fovy(90.0, 64, 64, 1.0), 90.0, 1.0e-9
    end

    test "a zoom narrows it, and a wider image narrows it more" do
      zoomed = Scene.zoom_fovy(90.0, 64, 64, 2.0)

      assert zoomed < 90.0
      assert Scene.zoom_fovy(90.0, 32, 64, 1.0) < Scene.zoom_fovy(90.0, 64, 64, 1.0)
    end
  end

  describe "an object" do
    test "that is a primitive is a geom, turned and scaled the way Monty turns it", %{root: root} do
      %{xml: xml, objects: [object]} =
        Scene.build(%{
          "data_path" => root,
          "agents" => agents(),
          "objects" => [
            %{"name" => "cubeSolid", "position" => [0.0, 1.5, 0.0], "scale" => [1.0, 1.0, 1.0]}
          ]
        })

      # Habitat's cube is a MuJoCo box at a tenth of the size.
      assert object.geom == "cubeSolid_0"
      assert xml =~ ~s(<geom name="cubeSolid_0" type="box" size="0.1 0.1 0.1")
    end

    test "that is a mesh has a texture, a material and its own scale", %{root: root} do
      %{xml: xml} =
        Scene.build(%{
          "data_path" => root,
          "agents" => agents(),
          "objects" => [%{"name" => "a_part", "position" => [0.0, 1.5, 0.0]}]
        })

      # No scale named is one: an object is its own size unless the experiment
      # says otherwise, and a zero would be an object shrunk to a point.
      assert xml =~ ~s(scale="1.0 1.0 1.0")
      assert xml =~ ~s(<texture name="a_part_1.0_1.0_1.0_tex")
      assert xml =~ ~s(<material name="a_part_1.0_1.0_1.0_mat")
      assert xml =~ ~s(<geom name="a_part_0" type="mesh" mesh="a_part_1.0_1.0_1.0_mesh")
    end

    test "has the reference pose its metadata states", %{root: root, object: object} do
      File.write!(
        Path.join(object, "metadata.json"),
        Jason.encode!(%{"refpos" => [0.1, 0.0, 0.0], "refquat" => [0.0, 1.0, 0.0, 0.0]})
      )

      %{xml: xml} =
        Scene.build(%{
          "data_path" => root,
          "agents" => agents(),
          "objects" => [%{"name" => "a_part"}]
        })

      assert xml =~ ~s(refpos="0.1 0.0 0.0")
      assert xml =~ ~s(refquat="0.0 1.0 0.0 0.0")
    end

    test "with metadata fields nobody knows is refused, not drawn wrong", %{
      root: root,
      object: object
    } do
      File.write!(
        Path.join(object, "metadata.json"),
        Jason.encode!(%{"ref_pos" => [0.0, 0.0, 0.0]})
      )

      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{
            "data_path" => root,
            "agents" => agents(),
            "objects" => [%{"name" => "a_part"}]
          })
        end

      assert error.message =~ "ref_pos"
    end

    test "that is not in the dataset is refused by name", %{root: root} do
      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{
            "data_path" => root,
            "agents" => agents(),
            "objects" => [%{"name" => "no_such_part"}]
          })
        end

      assert error.message =~ "no_such_part"
    end

    test "with no dataset to read it from is refused rather than guessed at" do
      error =
        assert_raise ArgumentError, fn ->
          Scene.build(%{"agents" => agents(), "objects" => [%{"name" => "a_part"}]})
        end

      assert error.message =~ "data path"
    end
  end
end
