defmodule Monty.Studio.StorageTest do
  @moduledoc """
  The room left where this deployment writes, asked of the operating system.

  The numbers belong to the machine the suite runs on, so what is held here is
  their shape and their relationships — a disk with a total, free space inside
  it, and a mount that is a directory — rather than any particular figure.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Storage
  alias Monty.Test.Tmp

  describe "the volume behind a path" do
    test "answers with the volume's own total, free space and capacity" do
      usage = Storage.usage(Tmp.dir("storage"))

      assert usage.path == Path.expand(usage.path)
      assert %{mount: mount} = usage.device
      assert File.dir?(mount)

      assert %{total_bytes: total, free_bytes: free, percent: percent} = usage.device

      assert total > 0
      assert free >= 0 and free <= total
      assert percent in 0..100
    end

    test "measures where the directory will be, before anyone has made it" do
      missing = Path.join(Tmp.dir("storage"), "runs/not/created/yet")
      refute File.exists?(missing)

      usage = Storage.usage(missing)

      assert usage.path == missing
      assert usage.device.total_bytes > 0
      assert File.dir?(usage.device.mount)
    end

    test "asks in absolute terms, whatever the working directory is" do
      relative = "priv/nothing-here"
      refute File.exists?(relative) and File.dir?(relative)

      assert %{path: path, device: %{total_bytes: total}} = Storage.usage(relative)

      assert Path.type(path) == :absolute
      assert total > 0
    end

    # The page says the room once rather than once per root, which it can only do
    # if the same disk answers with the same name for paths on it.
    test "two paths on one disk are answered with the one mount" do
      directory = Tmp.dir("storage/two")
      File.mkdir_p!(directory)

      assert Storage.usage(directory).device.mount ==
               Storage.usage(Path.join(directory, "deeper")).device.mount
    end
  end

  # The table is the operating system's, and which row answers for a path is the
  # one decision this module makes on its own — the half a unix box cannot
  # exercise for Windows, and a Windows box cannot for unix.
  describe "the row the operating system answers with" do
    test "is the longest mount that holds the path" do
      table = [
        {~c"/", 1_000_000, 400_000, 60},
        {~c"/Volumes/Backup", 2_000_000, 1_900_000, 5}
      ]

      assert Storage.volume_for(table, "/Users/someone/data") ==
               {~c"/", 1_000_000, 400_000, 60}

      assert Storage.volume_for(table, "/Volumes/Backup/runs") ==
               {~c"/Volumes/Backup", 2_000_000, 1_900_000, 5}
    end

    test "is the container the boot volume shares, for a path firmlinked into it" do
      # macOS names the data volume `/System/Volumes/Data` and reaches it from
      # `/Users` through a firmlink, so the path is not under that name. It is
      # the container and not the mount that holds the room, and `/` reports the
      # container's: the same free space as the volume the writes land on.
      table = [
        {~c"/", 1_000_000, 10_000, 97},
        {~c"/System/Volumes/Data", 1_000_000, 10_000, 97}
      ]

      assert Storage.volume_for(table, "/Users/someone/data") ==
               {~c"/", 1_000_000, 10_000, 97}
    end

    test "is a mount only for a path on the mount itself, never for its namesake" do
      table = [
        {~c"/", 1_000_000, 400_000, 60},
        {~c"/System/Volumes/Data2", 3_000_000, 3_000_000, 0}
      ]

      assert Storage.volume_for(table, "/System/Volumes/Data2/x") ==
               {~c"/System/Volumes/Data2", 3_000_000, 3_000_000, 0}
    end

    test "is the drive a Windows path names, whatever the separator or case" do
      table = [
        {~c"C:\\", 500_000, 100_000, 80},
        {~c"D:\\", 2_000_000, 1_500_000, 25}
      ]

      assert Storage.volume_for(table, "C:\\Users\\someone\\data") ==
               {~c"C:\\", 500_000, 100_000, 80}

      assert Storage.volume_for(table, "d:/data/runs") == {~c"D:\\", 2_000_000, 1_500_000, 25}
    end

    test "is nothing at all when the table holds no volume that could hold the path" do
      # A share that is not a fixed disk is not in the table, and a unix path is
      # not on a drive: the page says nothing rather than someone else's disk.
      assert Storage.volume_for([{~c"C:\\", 500_000, 100_000, 80}], "/Users/someone") == nil
      assert Storage.volume_for([], "/Users/someone") == nil

      assert Storage.volume_for([{~c"C:\\", 500_000, 100_000, 80}], "\\\\server\\share\\runs") ==
               nil
    end
  end
end
