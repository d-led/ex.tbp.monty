defmodule Monty.Studio.SetupDownloadLinkTest do
  @moduledoc """
  What an experiment that is only waiting for a download says, and where it sends
  the reader.

  "Download the objects on the Prerequisites page" is a sentence that leaves the
  reader to find the page, find the row and press it — the same distance from the
  problem as before they read it. The finding therefore carries the click.

  Sync, because it moves `MONTY_DATA`: these are the paths the *machine* has,
  and a test that pointed them at a temporary directory while another test read
  the real ones would be a race, not a stronger assertion.
  """

  use ExUnit.Case, async: false

  alias Monty.Studio.{Readiness, Setup}
  alias Monty.Test.Tmp

  # A config from the cows family: it steps a world of compositional objects,
  # which is the family this application has an archive for and a machine need
  # not have unpacked.
  @waiting_for_objects "base_infer_cows_large_compositional"

  setup do
    data = Tmp.dir("setup-download-link")
    Tmp.system_env("MONTY_DATA", data)

    :ok
  end

  test "a run waiting for its objects offers the download" do
    {:ok, setup} = Setup.from_experiment(@waiting_for_objects, world_simulator: :mujoco)

    assert [finding] = for(%{code: :world_data_missing} = f <- setup.findings, do: f)

    assert finding.level == :error
    assert finding.where == "environment.env_init_args.data_path"

    assert finding.message =~ "Not on this machine yet"
    refute finding.message =~ "cannot start here"

    assert %{label: label, href: "/prerequisites?fetch=compositional_objects_1_4_mujoco"} =
             finding.link

    assert label == "Download it"
  end

  # A download finishing is the one event that changes an answer without a config
  # changing, and the catalogue's answers are cached because composing all of
  # Monty's costs more than a page mount can pay. The cache therefore has to
  # notice the disk: the page said "waiting for prerequisites" for 21 rows while
  # the objects were unpacked and the command line said four.
  test "the catalogue stops saying waiting once the archive is there", %{} do
    data = System.get_env("MONTY_DATA")
    manifest = Tmp.file("downloads.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: objects
        title: Objects
        url: https://example.test/objects.tgz
        root: MONTY_DATA
        target: objects.tgz
        extract: true
        unpacks_to: compositional_objects_1.4_mujoco
    """)

    Tmp.app_env(:prerequisites_manifest, manifest)
    on_exit(&Readiness.forget/0)

    entry = fn ->
      Readiness.catalog(world_simulator: :mujoco)
      |> Map.fetch!(:entries)
      |> Enum.find(&(&1.name == @waiting_for_objects))
    end

    assert %{status: :refused, codes: [:world_data_missing]} = entry.()

    # An unpacked archive holds objects; an empty directory is the mkdir on the
    # way to some, and `Prerequisites.present?/1` counts only what holds
    # something.
    unpacked = Path.join([data, "compositional_objects_1.4_mujoco", "001_cube"])
    File.mkdir_p!(unpacked)
    File.write!(Path.join(unpacked, "object.obj"), "v 0 0 0")

    refute MapSet.member?(MapSet.new(entry.().codes), :world_data_missing)
  end
end
