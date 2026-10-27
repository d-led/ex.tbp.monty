defmodule Monty.Prerequisites.ArchiveTest do
  use ExUnit.Case, async: true

  alias Monty.Prerequisites.Archive

  setup do
    tmp = Path.join(System.tmp_dir!(), "archive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "staging"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  # A small archive that looks like a pretrained model: a directory, and files
  # in it. Written from memory, so nothing depends on the working directory.
  defp write_tar_gz(dir) do
    archive = Path.join(dir, "pretrained_ycb_v13.tgz")

    entries = [
      {~c"pretrained_ycb_v13/model.pt", "weights"},
      {~c"pretrained_ycb_v13/readme.md", "hello"}
    ]

    :ok = :erl_tar.create(to_charlist(archive), entries, [:compressed])
    archive
  end

  defp write_zip(dir) do
    archive = Path.join(dir, "pretrained_ycb_v13.zip")

    {:ok, _files} =
      :zip.create(to_charlist(archive), [{~c"pretrained_ycb_v13/model.pt", "weights"}])

    archive
  end

  test "a tarball is unpacked where it sits, into the directory it names", %{tmp: tmp} do
    archive = write_tar_gz(tmp)

    assert {:ok, 2} = Archive.extract(archive)

    assert File.exists?(Path.join([tmp, "pretrained_ycb_v13", "model.pt"]))
    assert File.read!(Path.join([tmp, "pretrained_ycb_v13", "readme.md"])) == "hello"
  end

  test "a zip is unpacked the same way", %{tmp: tmp} do
    archive = write_zip(tmp)

    assert {:ok, 1} = Archive.extract(archive)
    assert File.exists?(Path.join([tmp, "pretrained_ycb_v13", "model.pt"]))
  end

  test "an archive that is not an archive says so, with its path", %{tmp: tmp} do
    archive = Path.join(tmp, "pretrained_ycb_v13.tgz")
    File.write!(archive, "this is not a tarball")

    assert {:error, {:cannot_extract, path, _reason}} = Archive.extract(archive)
    assert path == archive
  end

  test "a format Monty does not ship is refused rather than guessed at", %{tmp: tmp} do
    archive = Path.join(tmp, "pretrained_ycb_v13.rar")
    File.write!(archive, "whatever")

    assert {:error, {:not_an_archive, ^archive}} = Archive.extract(archive)
  end

  test "the format is read from the name" do
    assert Archive.format("a.tgz") == :tar
    assert Archive.format("a.tar.gz") == :tar
    assert Archive.format("a.zip") == :zip
    assert Archive.format("a.tar") == :unknown
  end
end
