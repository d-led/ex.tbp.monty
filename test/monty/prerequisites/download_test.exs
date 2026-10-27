defmodule Monty.Prerequisites.DownloadTest do
  use ExUnit.Case, async: false

  alias Monty.Prerequisites
  alias Monty.Prerequisites.Download

  setup do
    tmp = Path.join(System.tmp_dir!(), "prereq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    manifest = Path.join(tmp, "prerequisites.yaml")

    File.write!(manifest, """
    prerequisites:
      - id: tiny
        title: Tiny archive
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny.tgz
      - id: tiny_bad_checksum
        title: Tiny archive with a wrong checksum
        url: https://example.test/tiny.tgz
        root: MONTY_DATA
        target: tiny-bad.tgz
        sha256: "0000000000000000000000000000000000000000000000000000000000000000"
    """)

    previous = System.get_env("MONTY_DATA")
    System.put_env("MONTY_DATA", Path.join(tmp, "data"))

    Application.put_env(:ex_tbp_monty, :prerequisites_manifest, manifest)
    Application.put_env(:ex_tbp_monty, :prerequisite_fetcher, Monty.Test.FakeFetcher)
    Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Download.topic())

    on_exit(fn ->
      if previous,
        do: System.put_env("MONTY_DATA", previous),
        else: System.delete_env("MONTY_DATA")

      Application.delete_env(:ex_tbp_monty, :prerequisites_manifest)
      Application.delete_env(:ex_tbp_monty, :prerequisite_fetcher)
      Application.delete_env(:ex_tbp_monty, :fake_download_result)
      Application.delete_env(:ex_tbp_monty, :fake_download_chunks)
      File.rm_rf!(tmp)
    end)

    {:ok, prerequisite: Prerequisites.get("tiny")}
  end

  describe "a successful download" do
    test "streams to a .part file, then moves it into place", %{prerequisite: prerequisite} do
      {:ok, pid} = Download.start(prerequisite)

      assert_receive {:download, %{id: "tiny", status: :done, bytes: 11}}, 1_000

      path = Prerequisites.target_path(prerequisite)
      assert File.read!(path) == "hello world"
      refute File.exists?(path <> ".part")
      assert Download.status(pid).status == :done
    end

    test "starts once: a second request returns the running download", %{
      prerequisite: prerequisite
    } do
      {:ok, first} = Download.start(prerequisite)
      {:ok, second} = Download.start(prerequisite)

      assert first == second
    end
  end

  describe "a download that cannot be trusted" do
    test "a wrong checksum leaves no finished file", %{prerequisite: _prerequisite} do
      {:ok, _pid} = Download.start(Prerequisites.get("tiny_bad_checksum"))

      assert_receive {:download, %{id: "tiny_bad_checksum", status: :failed, error: error}}, 1_000
      assert match?({:checksum_mismatch, _actual}, error)
    end

    test "a transport error is reported and the part file removed", %{prerequisite: prerequisite} do
      Application.put_env(:ex_tbp_monty, :fake_download_result, {:error, :connection_refused})

      {:ok, _pid} = Download.start(prerequisite)

      assert_receive {:download, %{id: "tiny", status: :failed, error: :connection_refused}},
                     1_000

      refute File.exists?(Prerequisites.target_path(prerequisite))
      refute File.exists?(Prerequisites.target_path(prerequisite) <> ".part")
    end
  end

  describe "progress" do
    test "reports the content length before the first finished message", %{
      prerequisite: prerequisite
    } do
      {:ok, _pid} = Download.start(prerequisite)

      assert_receive {:download, %{id: "tiny", total: 11}}, 1_000
    end
  end
end
