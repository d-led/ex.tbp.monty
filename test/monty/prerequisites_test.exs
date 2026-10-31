defmodule Monty.PrerequisitesTest do
  use ExUnit.Case, async: false

  alias Monty.Prerequisites
  alias Monty.Test.Tmp

  setup do
    previous = System.get_env("MONTY_MODELS")
    System.put_env("MONTY_MODELS", "/tmp/monty-models-test")

    on_exit(fn ->
      if previous,
        do: System.put_env("MONTY_MODELS", previous),
        else: System.delete_env("MONTY_MODELS")
    end)

    :ok
  end

  describe "the shipped manifest" do
    test "is found where the application keeps it, not where it happens to be running" do
      # A release runs from its own `bin`, so a relative `priv/...` would be a
      # file that is not there: the page that lists the prerequisites would
      # answer 500 in the image and work in a checkout.
      path = Prerequisites.manifest_path()

      assert File.exists?(path)
      assert Path.type(path) == :absolute
      assert Path.basename(path) == "prerequisites.yaml"
    end

    # One entry per thing a run actually reads. A release no config names is a
    # download that fixes nothing, so the list does not offer it.
    test "lists the archives a run of a current config reads, and no others" do
      ids = Enum.map(Prerequisites.all(), & &1.id)

      assert "pretrained_ycb_v14" in ids
      assert "ycb_objects_1_0" in ids
      refute Enum.any?(ids, &String.contains?(&1, "pretrained_ycb_v13"))
    end

    # A page that says "download them" and then offers only one of the two
    # things a MuJoCo run reads is a page that leaves the reader blocked after
    # the download. So the list has to cover the object meshes and the release
    # Monty's current configs name, each under the root Monty reads.
    test "covers both what a MuJoCo run reads: the meshes and the v14 memory" do
      entries = Prerequisites.all()

      assert Enum.any?(entries, fn entry ->
               entry.root == "MONTY_DATA" and
                 String.starts_with?(entry.target, "mujoco/objects/ycb/")
             end)

      assert Enum.any?(entries, fn entry ->
               entry.root == "MONTY_MODELS" and
                 String.starts_with?(entry.target, "pretrained_ycb_v14")
             end)
    end
  end

  describe "target_path/1" do
    test "puts a prerequisite under the environment variable Monty uses" do
      prerequisite = Prerequisites.get("pretrained_ycb_v14")

      assert Prerequisites.target_path(prerequisite) ==
               "/tmp/monty-models-test/pretrained_ycb_v14.tgz"
    end

    test "refuses a root Monty does not define" do
      assert_raise ArgumentError, ~r/unknown prerequisite root/, fn ->
        Prerequisites.root_path("SOMEWHERE_ELSE")
      end
    end
  end

  describe "present?/1" do
    test "is false until the file exists" do
      entry = %{
        id: "absent",
        title: "Absent",
        url: "https://example.test/absent.tgz",
        root: "MONTY_MODELS",
        target: "does-not-exist.tgz",
        sha256: nil
      }

      refute Prerequisites.present?(entry)
    end
  end

  describe "for_setup/1" do
    # The stand-in is the port's own scene: it reads nothing, so a checkout with
    # nothing downloaded can still run something.
    test "a stand-in run needs nothing off the disk" do
      assert Prerequisites.for_setup(%{world: :synthetic}) == []
    end

    test "Monty's own world names the data and the memory its config names" do
      data = Tmp.dir("monty-data")
      models = Tmp.dir("monty-models")
      Tmp.system_env("MONTY_DATA", data)
      Tmp.system_env("MONTY_MODELS", models)
      Tmp.system_env("MONTY_PYTHON", interpreter())

      setup = %{
        world: :habitat,
        environment: %{data_path: Path.join(data, "ycb")},
        model_name_or_path: "pretrained_ycb_v13"
      }

      File.mkdir_p!(setup.environment.data_path)
      File.mkdir_p!(Path.join(models, "pretrained_ycb_v13"))

      needs = Prerequisites.for_setup(setup)

      assert Enum.map(needs, & &1.kind) == [:interpreter, :data, :models]
      assert Enum.all?(needs, & &1.present?)
    end

    # A warning that says "missing" and nothing else sends the reader looking
    # through three directories by hand.
    test "says which are missing, and where each belongs" do
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))
      Tmp.without_env("MONTY_PYTHON")

      needs =
        Prerequisites.for_setup(%{world: :habitat, model_name_or_path: "pretrained_ycb_v13"})

      refute Enum.any?(needs, & &1.present?)
      assert Enum.map(needs, & &1.kind) == [:interpreter, :models]

      assert %{what: what} = Enum.find(needs, &(&1.kind == :interpreter))
      assert what =~ "MONTY_PYTHON"

      assert %{path: path} = Enum.find(needs, &(&1.kind == :models))
      assert path == Path.join(System.get_env("MONTY_MODELS"), "pretrained_ycb_v13")
    end

    test "a setup that names neither data nor memory reads only the interpreter" do
      Tmp.system_env("MONTY_PYTHON", interpreter())

      assert [%{kind: :interpreter, present?: true}] = Prerequisites.for_setup(%{world: :habitat})
    end
  end

  describe "engine/1" do
    test "names the engine an experiment's environment runs" do
      assert Prerequisites.engine(%{environment: %{module: %{class: "MuJoCoSimulator"}}}) ==
               :mujoco

      assert Prerequisites.engine(%{environment: %{module: %{class: "HabitatEnvironment"}}}) ==
               :habitat
    end

    test "names nothing when the environment is not a simulator Monty owns" do
      assert Prerequisites.engine(%{environment: %{module: %{class: "SomethingElse"}}}) == nil
      assert Prerequisites.engine(%{}) == nil
    end
  end

  describe "engine_installed?/1" do
    # The answer is a property of the build, not of the machine: `mujoco` is
    # installed into the interpreter this application carries, so a PATH with no
    # interpreter on it does not turn MuJoCo into a missing package. That is the
    # bug this replaces — a deployment with MuJoCo in it told its reader "not
    # available" because the page asked a `python3` nobody had chosen.
    test "asks the interpreter this application carries, not the PATH" do
      Tmp.without_env("MONTY_PYTHON")
      Tmp.system_env("PATH", "/nonexistent-bin")
      Prerequisites.forget_engines()
      on_exit(&Prerequisites.forget_engines/0)

      assert Prerequisites.engine_installed?(:mujoco)
      refute Prerequisites.engine_installed?(:habitat)
    end

    # A script or a test may have no interpreter of its own to point at; the
    # fallback asks the one a run would use, and its exit status is the answer —
    # a page that guessed from a directory name would say "installed" for a
    # package that fails to import.
    test "falls back to an operator's interpreter when nothing answers in-process" do
      Tmp.app_env(:python_imports?, {Prerequisites, :importable_in_environment})
      Tmp.system_env("MONTY_PYTHON", interpreter())
      Prerequisites.forget_engines()
      on_exit(&Prerequisites.forget_engines/0)

      assert Prerequisites.engine_installed?(:habitat)
    end
  end

  # An interpreter that answers every import with success. These tests are about
  # which world a run records and which files it reads, not about whether MuJoCo
  # is installed on the machine running them.
  defp interpreter do
    path = Tmp.file("python")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
