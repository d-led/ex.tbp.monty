defmodule Monty.Prerequisites.SagaTest do
  use ExUnit.Case, async: false

  alias Monty.Prerequisites
  alias Monty.Prerequisites.{Record, Saga}
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.dir("prereq")

    manifest = Path.join(tmp, "prerequisites.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: tiny
        title: Tiny archive
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny.tgz
      - id: tiny_unpacked
        title: Tiny archive that must be unpacked
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny-unpacked.tgz
        extract: true
      - id: tiny_bad_checksum
        title: Tiny archive with a wrong checksum
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny-bad.tgz
        sha256: "0000000000000000000000000000000000000000000000000000000000000000"
    """)

    previous = System.get_env("MONTY_DATA")
    previous_models = System.get_env("MONTY_MODELS")
    System.put_env("MONTY_DATA", Path.join(tmp, "data"))
    # The last phase of a fetch exports the memory of whatever pretrained
    # archive it unpacked. There is none under this root, so it finds nothing to
    # do — which is the phase, not an absence of one.
    System.put_env("MONTY_MODELS", Path.join(tmp, "models"))

    Application.put_env(:ex_tbp_monty, :prerequisites_manifest, manifest)
    Application.put_env(:ex_tbp_monty, :prerequisite_fetcher, Monty.Test.FakeFetcher)
    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Saga.topic())

    on_exit(fn ->
      # Stop any fetch still running before its directory disappears, so this
      # test cannot leak a process into the next one.
      Monty.Test.PrerequisiteDownloads.stop_all()

      if previous,
        do: System.put_env("MONTY_DATA", previous),
        else: System.delete_env("MONTY_DATA")

      if previous_models,
        do: System.put_env("MONTY_MODELS", previous_models),
        else: System.delete_env("MONTY_MODELS")

      Application.delete_env(:ex_tbp_monty, :prerequisites_manifest)
      Application.delete_env(:ex_tbp_monty, :prerequisite_fetcher)
      Application.delete_env(:ex_tbp_monty, :fake_download_result)
      Application.delete_env(:ex_tbp_monty, :fake_download_chunks)
    end)

    {:ok, prerequisite: Prerequisites.get("tiny"), tmp: tmp}
  end

  describe "a successful download" do
    test "streams to a .part file, then moves it into place", %{prerequisite: prerequisite} do
      {:ok, pid} = Saga.start(prerequisite)

      assert_receive {:download, %{id: "tiny", status: :done, bytes: 11}}, 2_000

      path = Prerequisites.target_path(prerequisite)
      assert File.read!(path) == "hello world"
      refute File.exists?(path <> ".part")
      assert Saga.status(pid).status == :done
    end

    test "starts once: a second request returns the running machine", %{
      prerequisite: prerequisite
    } do
      {:ok, first} = Saga.start(prerequisite)
      {:ok, second} = Saga.start(prerequisite)

      assert first == second
    end
  end

  describe "a prerequisite that arrives as an archive" do
    test "is unpacked where it lands, and says how many files came out", %{tmp: tmp} do
      write_archive(tmp)

      prerequisite = Prerequisites.get("tiny_unpacked")
      {:ok, _pid} = Saga.start(prerequisite)

      # Unpacking is a phase of the fetch, so it is reported as one.
      assert_receive {:download, %{id: "tiny_unpacked", status: :extracting}}, 1_000
      assert_receive {:download, %{id: "tiny_unpacked", status: :done, extracted: 1}}, 2_000

      unpacked =
        Path.join([
          Path.dirname(Prerequisites.target_path(prerequisite)),
          "pretrained_ycb_v13",
          "model.pt"
        ])

      assert File.exists?(unpacked)
    end

    test "ends by reading the memory the archive carries, and nothing when it carries none",
         %{tmp: tmp} do
      write_archive(tmp)

      {:ok, _pid} = Saga.start(Prerequisites.get("tiny_unpacked"))

      # This archive holds one file that is not a model, so there is no memory to
      # read and the fetch is finished when it is unpacked. What the next test
      # covers is the case that matters: an archive that does carry models.
      assert_receive {:download, %{id: "tiny_unpacked", status: :done, libraries: nil}}, 2_000
    end

    test "reads the models a released archive carries, at the depth it unpacks to",
         %{tmp: tmp} do
      # A released archive unpacks to a release directory:
      # `<archive>/<model>/pretrained/model.pt`, one level shallower than the
      # `MONTY_MODELS` root this used to look for. Asked to export that
      # directory, the exporter found nothing and the fetch reported a memory
      # read by reading none — while every run of that archive had nothing to
      # recognise with.
      write_release_archive(tmp, "tiny-unpacked")

      {:ok, _pid} = Saga.start(Prerequisites.get("tiny_unpacked"))

      assert_receive {:download, %{status: :exporting}}, 2_000

      assert_receive {:download,
                      %{
                        id: "tiny_unpacked",
                        status: :failed,
                        error: {:unread_memory, [model]}
                      }},
                     10_000

      # The model is named by the release the archive's own directory stands for.
      assert model == "tiny-unpacked/surf_agent_1lm"
    end

    test "an archive that will not unpack fails, with the reason" do
      Application.put_env(:ex_tbp_monty, :fake_download_chunks, ["not a tarball"])

      {:ok, _pid} = Saga.start(Prerequisites.get("tiny_unpacked"))

      assert_receive {:download, %{id: "tiny_unpacked", status: :failed, error: reason}}, 2_000
      assert {:cannot_extract, _path, _why} = reason
    end

    test "says which model it is reading while it reads the memory" do
      prerequisite = Prerequisites.get("tiny_unpacked")

      # Already here and unpacked: the machine goes straight to its last phase.
      land = Prerequisites.where_it_lands(prerequisite)
      write_unreadable_model(land, "surf_agent_1lm")

      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download,
                      %{
                        id: "tiny_unpacked",
                        status: :exporting,
                        export: %{model: "pretrained_ycb_v13/surf_agent_1lm", index: 1, total: 1}
                      }},
                     5_000
    end
  end

  describe "the phases are remembered" do
    test "an unpacked archive is not unpacked again", %{tmp: tmp} do
      prerequisite = Prerequisites.get("tiny_unpacked")
      write_archive(tmp)
      land = Prerequisites.where_it_lands(prerequisite)
      File.mkdir_p!(land)
      File.write!(Path.join(land, "already-here.txt"), "")

      # What a machine that finished unpacking left behind: the files, and the
      # note that the unpacking completed. A restart reads that note instead of
      # unpacking two hundred megabytes for a second time.
      Record.write(prerequisite, %{"id" => prerequisite.id, "unpacked" => true})

      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download, %{id: "tiny_unpacked", status: :done}}, 2_000
      refute_received {:download, %{id: "tiny_unpacked", status: :extracting}}
      refute_received {:download, %{id: "tiny_unpacked", status: :downloading}}
    end

    test "an archive on disk that was never unpacked is unpacked", %{tmp: tmp} do
      prerequisite = Prerequisites.get("tiny_unpacked")
      write_archive(tmp)

      # The bytes arrived and the process died before unpacking: nothing says
      # the unpacking happened, so the machine enters that phase rather than
      # believing the archive is a prerequisite.
      refute File.exists?(Record.path(prerequisite))

      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download, %{id: "tiny_unpacked", status: :extracting}}, 2_000
      assert_receive {:download, %{id: "tiny_unpacked", status: :done}}, 5_000
    end

    test "what happened is written beside the archive, so a restart can say it", %{
      prerequisite: prerequisite
    } do
      {:ok, _pid} = Saga.start(prerequisite)
      assert_receive {:download, %{id: "tiny", status: :done}}, 2_000

      record = Record.read(prerequisite)

      assert record["id"] == "tiny"
      assert record["status"] == "done"
      assert record["bytes"] == 11
    end
  end

  describe "the memory a run reads" do
    test "a model that cannot be read makes the fetch failed, not done", %{tmp: tmp} do
      prerequisite = Prerequisites.get("tiny_unpacked")
      write_archive(tmp)
      write_unreadable_model(Prerequisites.where_it_lands(prerequisite), "surf_agent_1lm")

      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download,
                      %{
                        id: "tiny_unpacked",
                        status: :failed,
                        error: {:unread_memory, ["pretrained_ycb_v13/surf_agent_1lm"]},
                        libraries: %{failed: [_one_model]}
                      }},
                     10_000
    end

    test "a fetch exports what its own archive carries, and nothing else", %{tmp: tmp} do
      prerequisite = Prerequisites.get("tiny_unpacked")
      write_archive(tmp)
      File.mkdir_p!(Prerequisites.where_it_lands(prerequisite))

      # A model beside the archive's own directory — somebody else's release,
      # or one fetched earlier. Asking the exporter to walk the whole models
      # root made every fetch read this one too, and fail on it.
      write_unreadable_model(Path.join(tmp, "models"), "some_other_model")

      {:ok, _pid} = Saga.start(prerequisite)

      # Nothing to read here, so nothing was read: had it walked the models root,
      # this fetch would have named the model above as a failure.
      assert_receive {:download, %{id: "tiny_unpacked", status: :done, libraries: nil}}, 10_000
    end
  end

  describe "a download that cannot be trusted" do
    test "a wrong checksum leaves no finished file", %{prerequisite: _prerequisite} do
      {:ok, _pid} = Saga.start(Prerequisites.get("tiny_bad_checksum"))

      assert_receive {:download, %{id: "tiny_bad_checksum", status: :failed, error: error}},
                     2_000

      assert match?({:checksum_mismatch, _actual}, error)
    end

    test "a transport error is reported and the part file removed", %{prerequisite: prerequisite} do
      Application.put_env(:ex_tbp_monty, :fake_download_result, {:error, :connection_refused})

      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download, %{id: "tiny", status: :failed, error: :connection_refused}},
                     2_000

      refute File.exists?(Prerequisites.target_path(prerequisite))
      refute File.exists?(Prerequisites.target_path(prerequisite) <> ".part")
    end
  end

  describe "cancelling" do
    test "a download that has already finished is nothing to do", %{prerequisite: prerequisite} do
      {:ok, pid} = Saga.start(prerequisite)
      assert_receive {:download, %{id: "tiny", status: :done}}, 2_000

      # The page may still be holding the pid; asking it to cancel must not
      # raise once the process is gone.
      _ = :gen_statem.stop(pid)

      assert Saga.cancel(pid) == {:error, :not_found}
    end
  end

  describe "the folder a download lands in" do
    test "is created before the download starts, however deep it is", %{tmp: tmp} do
      manifest = Path.join(tmp, "deep.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: deep
          title: Deep target
          url: https://example.test/tiny.tgz
          root: MONTY_DATA
          target: nested/deeper/tiny.tgz
      """)

      Application.put_env(:ex_tbp_monty, :prerequisites_manifest, manifest)
      prerequisite = Prerequisites.get("deep")

      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download, %{id: "deep", status: :done}}, 2_000
      assert File.exists?(Path.join([tmp, "data", "nested", "deeper", "tiny.tgz"]))
    end

    test "a folder that cannot be created is reported, not crashed into" do
      # A file where the folder should be: `mkdir` cannot make it, and no
      # download process may be left behind.
      blocker = Tmp.file("blocked")
      File.write!(blocker, "not a directory")

      Tmp.system_env("MONTY_DATA", Path.join(blocker, "data"))

      manifest = Tmp.file("blocked.yaml")

      File.write!(manifest, """
      prerequisites:
        - id: blocked
          title: Blocked target
          url: https://example.test/tiny.tgz
          root: MONTY_DATA
          target: tiny.tgz
      """)

      Tmp.app_env(:prerequisites_manifest, manifest)

      assert {:error, {:cannot_create, _directory, _reason}} =
               Saga.start(Prerequisites.get("blocked"))
    end
  end

  describe "progress" do
    test "reports the content length before the first finished message", %{
      prerequisite: prerequisite
    } do
      {:ok, _pid} = Saga.start(prerequisite)

      assert_receive {:download, %{id: "tiny", total: 11}}, 2_000
    end
  end

  # A tiny tgz carrying one pickle, offered to the fake fetcher as the bytes of
  # the next download.
  defp write_archive(tmp) do
    archive = Path.join(tmp, "tiny.tgz")

    :ok =
      :erl_tar.create(
        to_charlist(archive),
        [{~c"pretrained_ycb_v13/model.pt", "weights"}],
        [:compressed]
      )

    Application.put_env(:ex_tbp_monty, :fake_download_chunks, [File.read!(archive)])
    archive
  end

  # The same, shaped like a released archive: its own top-level directory (which
  # is why an archive's contents land where `where_it_lands/1` says), one model
  # under it, and that model's pickle under `pretrained/`.
  defp write_release_archive(tmp, release) do
    archive = Path.join(tmp, "release.tgz")

    :ok =
      :erl_tar.create(
        to_charlist(archive),
        [{~c"#{release}/surf_agent_1lm/pretrained/model.pt", "not a torch save"}],
        [:compressed]
      )

    Application.put_env(:ex_tbp_monty, :fake_download_chunks, [File.read!(archive)])
    archive
  end

  # A model the exporter will reach and fail on, at `<root>/<release>/<name>/pretrained/model.pt`
  # — the shape `Monty.Studio.Pretrained.models/1` looks for.
  defp write_unreadable_model(root, name) do
    pickle = Path.join([root, "pretrained_ycb_v13", name, "pretrained", "model.pt"])
    File.mkdir_p!(Path.dirname(pickle))
    File.write!(pickle, "not a torch save")
    pickle
  end
end
