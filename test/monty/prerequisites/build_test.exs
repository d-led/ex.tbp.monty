defmodule Monty.Prerequisites.BuildTest do
  @moduledoc """
  The inputs this application makes, driven the way `/prerequisites` drives
  them.

  The point of each case is the same question the page asks: after one click, is
  there a memory and an object set at the path the configs already name? The
  geometry is `ex_monty_cad`'s, from Hex, so a checkout with `mix deps.get` can
  answer it.

  Two of the memories a CAD click writes are taught at a patch's own scale, which
  is minutes of geometry: the blend is 163 s and the set of two parts 467 s on a
  ten-core Mac on 2026-11-19, against a case budget of 300 s. So the click's loop
  is driven with the teaching named (`:plans` and `:prepare`, the seam
  `Monty.Prerequisites.Saga` already uses), the agreement between the configs and
  what the manifest promises is asserted without geometry, and three plans are
  taught for real — one part, one set at the surface policy's own stand-off, and
  one part as features.
  """

  use ExUnit.Case, async: false

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Build
  alias Monty.Studio.Cad.Preparation
  alias Monty.Test.PrerequisiteRoots

  setup do
    root = Path.join(System.tmp_dir!(), "build-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:ex_tbp_monty, :glb_getter)
    end)

    {:ok, root: root}
  end

  describe "a name this application cannot build" do
    test "is refused with a sentence rather than a silent nothing" do
      assert {:error, message} = Build.run("something_nobody_wrote", fn _ -> :ok end)
      assert message =~ "something_nobody_wrote"
    end
  end

  describe "the CAD parts" do
    # The click's own loop, with the teaching named rather than done: one line
    # per memory, and a refusal that names the part it is about. The teaching
    # itself is the next describe, because a memory at a patch's own scale takes
    # minutes — the set of two parts took 467 s on a ten-core Mac on 2026-11-19 —
    # and a case that runs all five would spend CI's whole budget proving that
    # four of them are the same code path.
    test "is one line per memory, and a refusal says which part it was" do
      plans = [
        %{part: "plate", memory: "/libraries/plate_part.jsonl.gz"},
        %{part: "blend", memory: "/libraries/blend_part.jsonl.gz"}
      ]

      steps = self()

      taught = fn %{part: part} ->
        send(steps, {:taught, part})
        {:ok, %{written: 1, nodes: 7}}
      end

      assert {:ok, said} =
               Build.run("cad_part_memories", &send(steps, {:step, &1}),
                 plans: plans,
                 prepare: taught
               )

      assert length(said) == length(plans)
      assert_received {:taught, "plate"}
      assert_received {:taught, "blend"}
      assert_received_step(:first)
    end

    test "names every part of a set, not only the first it teaches" do
      set = %{
        part: "plate",
        parts: [{"plate", "/parts/plate.step"}, {"blend", "/parts/blend.step"}],
        memory: "/libraries/parts_set.jsonl.gz"
      }

      steps = self()

      assert {:ok, [said]} =
               Build.run("cad_part_memories", &send(steps, {:step, &1}),
                 plans: [set],
                 prepare: fn _ -> {:ok, %{written: 2, nodes: 9}} end
               )

      assert_received {:step, %{what: what}}
      assert what =~ "plate, blend"
      assert said =~ "plate, blend"
    end

    test "says when a memory was left as it was rather than taught again" do
      plans = [%{part: "plate", memory: "/libraries/plate_part.jsonl.gz"}]

      assert {:ok, [said]} =
               Build.run("cad_part_memories", fn _ -> :ok end,
                 plans: plans,
                 prepare: fn _ -> {:ok, %{written: 1, nodes: 7, taught: :before}} end
               )

      assert said =~ "already taught from the same inputs"
    end

    test "stops at the part it could not teach" do
      plans = [
        %{part: "plate", memory: "/libraries/plate_part.jsonl.gz"},
        %{part: "blend", memory: "/libraries/blend_part.jsonl.gz"}
      ]

      taught = fn
        %{part: "plate"} -> {:ok, %{written: 1, nodes: 7}}
        %{part: "blend"} -> {:error, "the blend's STEP file is not here"}
      end

      assert {:error, message} =
               Build.run("cad_part_memories", fn _ -> :ok end, plans: plans, prepare: taught)

      assert message =~ "blend"
    end

    test "every memory the CAD configs load is one this build promises" do
      promised =
        "cad_part_memories"
        |> Prerequisites.get()
        |> Prerequisites.promised_memories()
        |> Enum.map(&Path.basename(&1, ".jsonl.gz"))

      planned = Enum.map(Build.plans(), &memory_name/1)

      assert Enum.sort(planned) == Enum.sort(promised)
    end
  end

  describe "a memory taught for real" do
    @describetag timeout: 300_000

    test "is one memory and one mesh per object the experiment steps", %{root: root} do
      PrerequisiteRoots.with_roots(root, fn ->
        {plan, setup} = experiment("plate_part_eval")

        assert {:ok, written} = Preparation.prepare(plan)
        assert written.written == 1

        assert File.exists?(plan.memory)
        assert_meshed(setup)
      end)
    end

    test "is one file holding every part of a set, and a mesh for each", %{root: root} do
      PrerequisiteRoots.with_roots(root, fn ->
        {plan, setup} = experiment("parts_set_eval")

        # At the surface policy's own 25 mm stand-off rather than the set's 8 mm:
        # the same code path through `Preparation.prepare/1`, four minutes
        # cheaper. What a config's optics do — the patch it is read through, and
        # the spacing that follows from it — is `preparation_test`'s, pinned
        # there without geometry.
        plan = %{plan | optics: %{plan.optics | distance: 25.0}}

        assert {:ok, written} = Preparation.prepare(plan)

        assert written.written == length(Monty.Studio.Setup.objects(setup))
        assert File.exists?(plan.memory)
        assert_meshed(setup)
      end)
    end

    test "as features holds the objects the feature experiment steps, one per feature", %{
      root: root
    } do
      PrerequisiteRoots.with_roots(root, fn ->
        {plan, setup} = experiment("plate_features_eval")

        assert {:ok, written} = Preparation.prepare(plan)

        # The feature experiment's env interface names the memory's own objects —
        # `plate_bosses_0` and its three siblings — so a memory holding a different
        # number of them is a memory the run cannot step, which is the thing worth
        # asserting rather than "more than one part".
        assert written.written == length(Monty.Studio.Setup.objects(setup))
        assert File.exists?(plan.memory)
        assert_meshed(setup)
      end)
    end
  end

  describe "a corpus" do
    test "that cannot be fetched says which object refused, and writes no object set", %{
      root: root
    } do
      PrerequisiteRoots.with_roots(root, fn ->
        Application.put_env(:ex_tbp_monty, :glb_getter, fn _url, _opts ->
          {:error, :timeout}
        end)

        assert {:error, message} = Build.run("objaverse_dogs", fn _ -> :ok end)
        assert message =~ "failed"

        into = Path.join(Prerequisites.root_path("MONTY_DATA"), "mujoco/objects/objaverse_dogs")
        refute File.exists?(into)
      end)
    end

    test "whose files are all here is imported without touching the network", %{root: root} do
      PrerequisiteRoots.with_roots(root, fn ->
        Application.put_env(:ex_tbp_monty, :glb_getter, fn url, _opts ->
          flunk("a cached corpus is not fetched again, and this asked for #{url}")
        end)

        cache = Path.join(Prerequisites.root_path("MONTY_DATA"), "downloads/objaverse_dogs")
        File.mkdir_p!(cache)

        # Every uid the manifest names, cached — and what the import makes of a
        # file that is not a GLB is its own refusal, which is what this asserts:
        # the fetch step is skipped, the import step is reached, and the build
        # reports the refusal instead of pretending it wrote an object set.
        uids = manifest_uids()

        for uid <- uids, do: File.write!(Path.join(cache, uid <> ".glb"), "not a glb")

        assert {:error, message} = Build.run("objaverse_dogs", fn _ -> :ok end)
        assert message =~ "could not import"
      end)
    end
  end

  # The CAD set's own experiment configs, which is what a build reads: a name is
  # a config file, and the part it steps is in its env interface.
  defp experiment(name) do
    {:ok, opened} = Monty.Studio.open("cad/#{name}", conf_dir: Monty.Config.Source.conf_dirs())
    {:ok, plan} = Preparation.plan(opened.setup)
    {plan, opened.setup}
  end

  # A plan names the file a run loads and the config names a memory; the promise
  # in `priv/prerequisites.yaml` is the bare name, in a release folder.
  defp memory_name(plan), do: Path.basename(plan.memory, ".jsonl.gz")

  # Every object the run steps, not only the first: a memory of a part's features
  # answers several names, and a run is only able to ask about the ones that were
  # written as directories.
  defp assert_meshed(setup) do
    objects = Path.join(Prerequisites.root_path("MONTY_DATA"), "cad_objects")

    for object <- Monty.Studio.Setup.objects(setup) do
      assert File.dir?(Path.join(objects, object)),
             "the run steps #{object}, which the build did not write a mesh for"
    end
  end

  defp manifest_uids do
    manifest =
      Path.join([
        :code.priv_dir(:ex_tbp_monty),
        "monty_experiments/sets/dogs/objaverse_dogs.json"
      ])

    manifest
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("objects")
    |> Enum.map(& &1["uid"])
  end

  defp assert_received_step(:first) do
    assert_receive {:step, %{index: 1, total: total, what: what}}
    assert total > 0
    assert is_binary(what) and what != ""
  end
end
