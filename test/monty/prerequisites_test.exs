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

    # The manifest is the one place an archive is declared, so the list has to
    # be safe to extend: an entry that forgets where it goes, or points at a root
    # this application does not define, is a download that fails at a person's
    # click rather than at the edit.
    test "every entry names what a download needs, and only roots Monty defines" do
      for entry <- Prerequisites.all() do
        assert is_binary(entry.id) and entry.id != "", "an entry has no id: #{inspect(entry)}"
        assert is_binary(entry.title) and entry.title != "", "#{entry.id} has no title"
        assert String.starts_with?(entry[:url] || "", "https://"), "#{entry.id} has no https url"
        assert is_binary(entry.target) and entry.target != "", "#{entry.id} has no target"
        assert entry.root in ~w(MONTY_DATA MONTY_MODELS MONTY_LOGS), "#{entry.id}: #{entry.root}"
      end
    end

    test "gives each entry its own id, so two archives cannot be one file" do
      ids = Enum.map(Prerequisites.all(), & &1.id)

      assert ids == Enum.uniq(ids)
    end
  end

  describe "which download fills a directory" do
    # A run names the directory its objects belong in, and a person reading that
    # name needs the archive that puts them there — the manifest already knows
    # where each entry lands, so the answer is read off it rather than guessed
    # from a file name.
    test "names the entry that unpacks to a directory, and none for one nothing fills" do
      Tmp.system_env("MONTY_DATA", Tmp.dir("for-path"))

      cows = Prerequisites.get("compositional_objects_1_4_mujoco")

      assert %{id: "compositional_objects_1_4_mujoco"} =
               Prerequisites.for_path(Prerequisites.where_it_lands(cows))

      assert Prerequisites.for_path("/somewhere/nothing-unpacks-here") == nil
    end

    test "reads the archive's own name when an entry does not say where it lands" do
      data = Tmp.dir("for-path-name")
      Tmp.system_env("MONTY_DATA", data)
      manifest = Tmp.file("by-name.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: ycb
          title: YCB
          url: https://example.test/ycb.tgz
          root: MONTY_DATA
          target: ycb_objects_1.0.tgz
          extract: true
      """)

      assert %{id: "ycb"} =
               Prerequisites.for_path(Path.join(data, "ycb_objects_1.0"), manifest)
    end
  end

  describe "unfinished/0" do
    # A file that is here is finished; one that never arrived is not. The third
    # case is the one that used to be reported as finished: an archive on disk,
    # unpacked or not, whose memory no run has read.
    test "names what is absent, and what arrived without being finished" do
      tmp = Tmp.dir("unfinished")
      Tmp.system_env("MONTY_DATA", Path.join(tmp, "data"))
      File.mkdir_p!(Path.join(tmp, "data"))

      manifest = Tmp.file("unfinished.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: absent
          title: Not here
          url: https://example.test/a.tgz
          root: MONTY_DATA
          target: absent.txt
        - id: here
          title: Here as a file
          url: https://example.test/b.tgz
          root: MONTY_DATA
          target: here.txt
        - id: archive
          title: An archive
          url: https://example.test/c.tgz
          root: MONTY_DATA
          target: archive.tgz
          extract: true
      """)

      Tmp.app_env(:prerequisites_manifest, manifest)
      File.write!(Path.join([tmp, "data", "here.txt"]), "here")
      File.write!(Path.join([tmp, "data", "archive.tgz"]), "bytes")

      assert Enum.map(Prerequisites.unfinished(), & &1.id) == ["absent", "archive"]
    end

    # An unpacked archive is not finished while a model inside it has no library:
    # a run reads the libraries, and verifying them is the work. Which is why a
    # boot asks this rather than "is the file there".
    test "an unpacked archive with memory still to read is unfinished" do
      tmp = Tmp.dir("unfinished-unpacked")
      Tmp.system_env("MONTY_DATA", Path.join(tmp, "data"))
      Tmp.system_env("MONTY_MODELS", Path.join(tmp, "models"))
      land = Path.join([tmp, "data", "archive"])

      manifest = Tmp.file("unpacked.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: archive
          title: An archive
          url: https://example.test/c.tgz
          root: MONTY_DATA
          target: archive.tgz
          extract: true
      """)

      Tmp.app_env(:prerequisites_manifest, manifest)
      Tmp.app_env(:monty_libraries_dir, Path.join(tmp, "libraries"))

      # The archive's own bytes and its unpacked model, with no library beside
      # them: whatever a run would need, it would not find it.
      File.mkdir_p!(land)
      File.write!(Path.join([tmp, "data", "archive.tgz"]), "bytes")
      model = Path.join([land, "surf_agent_1lm", "pretrained", "model.pt"])
      File.mkdir_p!(Path.dirname(model))
      File.write!(model, "not a torch save")

      prerequisite = Prerequisites.get("archive")
      Monty.Prerequisites.Record.write(prerequisite, %{"id" => "archive", "unpacked" => true})

      assert Enum.map(Prerequisites.unfinished(), & &1.id) == ["archive"]
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
      libraries = Tmp.dir("monty-libraries")
      Tmp.system_env("MONTY_DATA", data)
      Tmp.system_env("MONTY_MODELS", models)
      Tmp.system_env("MONTY_PYTHON", interpreter())
      Tmp.app_env(:monty_libraries_dir, libraries)

      setup = %{
        world: :mujoco,
        environment: %{data_path: Path.join(data, "ycb")},
        model_name_or_path: "pretrained_ycb_v13"
      }

      # An object bundle holds an object; an empty directory is the state this
      # check exists to tell apart from a download.
      object = Path.join(setup.environment.data_path, "mug")
      File.mkdir_p!(object)
      File.write!(Path.join(object, "textured.obj"), "")
      # And the memory is the library a run reads, not the model it was exported
      # from: a config can sit beside pickles that were never read.
      library = Monty.Studio.Memory.path_for("pretrained_ycb_v13", "pretrained_ycb_v13")
      File.mkdir_p!(Path.dirname(library))
      File.write!(library, "")

      needs = Prerequisites.for_setup(setup)

      assert Enum.map(needs, & &1.kind) == [:data, :models]
      assert Enum.all?(needs, & &1.present?)
    end

    # A warning that says "missing" and nothing else sends the reader looking
    # through three directories by hand.
    test "says which are missing, and where each belongs" do
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))
      Tmp.without_env("MONTY_PYTHON")

      needs =
        Prerequisites.for_setup(%{world: :mujoco, model_name_or_path: "pretrained_ycb_v13"})

      refute Enum.any?(needs, & &1.present?)
      assert Enum.map(needs, & &1.kind) == [:models]

      assert %{path: path} = Enum.find(needs, &(&1.kind == :models))
      assert path == Path.join(System.get_env("MONTY_MODELS"), "pretrained_ycb_v13")
    end

    # No operator interpreter to check any more: the world steps in the
    # interpreter this application carries, so a setup that names no data and no
    # memory reads nothing.
    test "a setup that names neither data nor memory needs nothing" do
      assert Prerequisites.for_setup(%{world: :mujoco}) == []
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

  describe "size/1" do
    test "says nothing is there rather than zero bytes" do
      tmp = Tmp.dir("size-absent")
      Tmp.system_env("MONTY_DATA", Path.join(tmp, "data"))
      prerequisite = manifest_entry(tmp, "absent.txt", false)

      assert Prerequisites.size(prerequisite) == %{archive: nil, unpacked: nil}
    end

    test "counts the archive and everything it unpacked to" do
      tmp = Tmp.dir("size-here")
      Tmp.system_env("MONTY_DATA", Path.join(tmp, "data"))
      prerequisite = manifest_entry(tmp, "archive.tgz", true)

      File.mkdir_p!(Path.join(tmp, "data"))
      File.write!(Prerequisites.target_path(prerequisite), :binary.copy("a", 100))

      # A directory's own entry is the size of its name, not of what is in it:
      # the answer a person wants is what the unpacked tree takes.
      land = Path.join([tmp, "data", "archive", "nested"])
      File.mkdir_p!(land)
      File.write!(Path.join([tmp, "data", "archive", "one.txt"]), :binary.copy("b", 40))
      File.write!(Path.join(land, "two.txt"), :binary.copy("c", 60))

      assert Prerequisites.size(prerequisite) == %{archive: 100, unpacked: 100}
    end
  end

  # The page asks this of a *root*, not of a bundle: `pretrained_models` holds
  # several releases beside the one a run reads. A root is also where links
  # live (`pretrained_ycb_v12 -> pretrained_ycb_v11`), and a walk that followed
  # them would count a release twice — or, with a link pointing back, not finish
  # at all.
  describe "directory_size/1" do
    test "counts the files under a directory, and a link inside it is not a second copy" do
      tmp = Tmp.dir("directory-size")

      assert Prerequisites.directory_size(Path.join(tmp, "absent")) == nil

      tree = Path.join(tmp, "present")
      File.mkdir_p!(Path.join(tree, "nested"))
      File.write!(Path.join(tree, "one.txt"), :binary.copy("a", 40))
      File.write!(Path.join([tree, "nested", "two.txt"]), :binary.copy("b", 60))
      File.ln_s!(tree, Path.join(tree, "back"))

      assert Prerequisites.directory_size(tree) == 100
    end
  end

  # One entry, under a manifest of its own, so a test names only what it needs.
  defp manifest_entry(tmp, target, extract?) do
    manifest = Path.join(tmp, "size.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: sized
        title: Sized
        url: https://example.test/sized.tgz
        root: MONTY_DATA
        target: #{target}
        extract: #{extract?}
    """)

    Tmp.app_env(:prerequisites_manifest, manifest)
    Prerequisites.get("sized")
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

      assert Prerequisites.engine_installed?(:mujoco)
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

  describe "which archive carries a memory" do
    test "is the archive that unpacks the release and lists the model" do
      # `pretrained_ycb_v14` is the directory the archive unpacks, and the models
      # inside it are the ones Monty published — so a config naming one of them
      # is a download away.
      assert %{id: "pretrained_ycb_v14"} =
               Prerequisites.for_model("surf_agent_1lm_10distinctobj", "pretrained_ycb_v14")

      assert %{id: "pretrained_compositional_objects_v8"} =
               Prerequisites.for_model(
                 "supervised_pre_training_cows_large_compositional",
                 "pretrained_compositional_objects_v8"
               )
    end

    test "is nobody for a memory no archive lists" do
      # The tutorial's evaluation config reads what its own training run writes:
      # there is no archive to fetch, and the page must not pretend otherwise.
      assert Prerequisites.for_model("surf_agent_1lm_2obj_train", "projects") == nil

      # A model in the right release that the archive does not hold is the same
      # answer: the archive carries the models it was published with.
      assert Prerequisites.for_model("a_model_nobody_exported", "pretrained_ycb_v14") == nil
      assert Prerequisites.for_model(nil, "pretrained_ycb_v14") == nil
    end
  end
end
