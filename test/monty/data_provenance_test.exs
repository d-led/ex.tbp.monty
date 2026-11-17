defmodule Monty.DataProvenanceTest do
  @moduledoc """
  The record of where our data came from, held to the bytes.

  Every data set this application reads is described in
  `priv/data_provenance.yaml`: its origin, whose work it is, what produced it,
  and a hash. These cases are what makes that more than a page: a file that
  changed without the record changing, or a data file that arrived with no entry
  at all, is a failing suite rather than a surprise months later.
  """

  use ExUnit.Case, async: true

  alias Monty.DataProvenance

  # Two very small trees: a record is about bytes, and the fixture is bytes.
  setup do
    dir = Path.join(System.tmp_dir!(), "provenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write(root, path, contents) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
    full
  end

  defp record(dir, entries, opts \\ []) do
    path = Path.join(dir, "record.yaml")

    File.write!(path, """
    roots: #{flow_list(Enum.map(Keyword.get(opts, :roots, ["data"]), &Path.join(dir, &1)))}
    exclude: #{flow_list(Keyword.get(opts, :exclude, []))}
    data:
    #{Enum.map_join(entries, "", &entry_block(dir, &1))}
    """)

    path
  end

  defp entry_block(dir, entry) do
    entry
    |> Map.new(fn {key, value} ->
      {key, if(key == :path, do: Path.join(dir, value), else: value)}
    end)
    |> Enum.map_join("", fn {key, value} -> "    #{key}: #{value}\n" end)
    |> then(&("  - kind: recorded\n    title: a fixture\n" <> &1))
  end

  defp flow_list(values), do: "[" <> Enum.map_join(values, ", ", &"\"#{&1}\"") <> "]"

  describe "a file's hash" do
    test "is the sha256 of its bytes", %{dir: dir} do
      file = write(dir, "fixture.txt", "one bite")

      assert DataProvenance.file_hash(file) ==
               :crypto.hash(:sha256, "one bite") |> Base.encode16(case: :lower)
    end
  end

  describe "a directory's hash" do
    test "changes when a file inside it is added, edited or removed", %{dir: dir} do
      data = Path.join(dir, "data")
      write(data, "a.json", "{}")
      write(data, "b.json", "[]")

      alone = DataProvenance.hash_of(data)

      File.write!(Path.join(data, "b.json"), "[1]")
      edited = DataProvenance.hash_of(data)

      File.rm!(Path.join(data, "b.json"))
      removed = DataProvenance.hash_of(data)

      refute edited == alone
      refute removed == alone
      refute removed == edited

      # And a set that comes back to what it was says so, which is what makes
      # the number worth recording.
      File.write!(Path.join(data, "b.json"), "[]")
      assert DataProvenance.hash_of(data) == alone
    end
  end

  describe "checking the record against the tree" do
    test "answers nothing wrong when every entry matches", %{dir: dir} do
      write(dir, "data/a.json", "{}")

      manifest =
        record(dir, [
          %{path: "data/a.json", hash: DataProvenance.hash_of(Path.join(dir, "data/a.json"))}
        ])

      assert DataProvenance.check(manifest) == %{
               missing: [],
               unhashed: [],
               drifted: [],
               undeclared: []
             }
    end

    test "names an entry whose bytes changed, and what it should say instead", %{dir: dir} do
      write(dir, "data/a.json", "{}")
      stale = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

      manifest = record(dir, [%{path: "data/a.json", hash: stale}])

      assert %{drifted: [drift]} = DataProvenance.check(manifest)
      assert drift.path == Path.join(dir, "data/a.json")
      assert drift.expected == stale
      assert drift.actual == DataProvenance.hash_of(Path.join(dir, "data/a.json"))
    end

    # A digest of digits only is a number to YAML. Accepting it would be a record
    # that never matches its file and never says so, so it counts as no hash.
    test "counts a hash that is not a sha256 as no hash at all", %{dir: dir} do
      write(dir, "data/a.json", "{}")
      manifest = record(dir, [%{path: "data/a.json", hash: "00000000000000000000000000000000"}])

      assert %{unhashed: [unhashed], drifted: []} = DataProvenance.check(manifest)
      assert unhashed == Path.join(dir, "data/a.json")
    end

    test "names a data file no entry mentions", %{dir: dir} do
      write(dir, "data/a.json", "{}")
      write(dir, "data/b.json", "{}")

      manifest =
        record(dir, [
          %{path: "data/a.json", hash: DataProvenance.hash_of(Path.join(dir, "data/a.json"))}
        ])

      assert %{undeclared: [undeclared]} = DataProvenance.check(manifest)
      assert undeclared == Path.join(dir, "data/b.json")
    end

    test "a directory entry speaks for every file under it", %{dir: dir} do
      write(dir, "data/set/a.json", "{}")
      write(dir, "data/set/nested/b.yaml", "x: 1")

      manifest =
        record(dir, [
          %{path: "data/set", hash: DataProvenance.hash_of(Path.join(dir, "data/set"))}
        ])

      assert %{undeclared: [], drifted: []} = DataProvenance.check(manifest)
    end

    test "an entry that says no hash, or points at nothing, is a failure of its own", %{dir: dir} do
      write(dir, "data/a.json", "{}")
      manifest = record(dir, [%{path: "data/a.json"}, %{path: "data/gone.json", hash: "abc"}])

      assert %{unhashed: [unhashed], missing: [missing]} = DataProvenance.check(manifest)
      assert unhashed == Path.join(dir, "data/a.json")
      assert missing == Path.join(dir, "data/gone.json")
    end

    test "a pattern to exclude keeps a download out of the record's way", %{dir: dir} do
      write(dir, "data/a.json", "{}")
      write(dir, "data/downloaded/big.jsonl", "{}")

      manifest =
        record(
          dir,
          [%{path: "data/a.json", hash: DataProvenance.hash_of(Path.join(dir, "data/a.json"))}],
          exclude: ["downloaded/**/*"]
        )

      assert %{undeclared: []} = DataProvenance.check(manifest)
    end
  end

  describe "this repository's own record" do
    # The record that ships, not a fixture: the point of the file is that it is
    # true of the tree it sits in, and this is the case that says so.
    test "describes every data file the tree carries, with the hash the bytes have" do
      assert DataProvenance.check() == %{missing: [], unhashed: [], drifted: [], undeclared: []}
    end

    test "does not describe a pretrained memory, because none is in git" do
      paths = Enum.map(DataProvenance.entries(), & &1.path)

      refute Enum.any?(paths, &String.starts_with?(&1, "priv/monty/libraries"))
    end
  end
end
