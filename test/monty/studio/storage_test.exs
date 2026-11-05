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

  # Windows has no `df`: the drive table `os_mon`'s `disksup` holds is asked
  # instead, and this is the half of the module a machine without drives cannot
  # exercise — so it is given the table rather than reading one.
  describe "the drive behind a path on Windows" do
    test "answers with the drive the path is on" do
      volumes = [
        {~c"C:\\", 100 * 1024, 40 * 1024, 60},
        {~c"D:\\", 200 * 1024, 150 * 1024, 25}
      ]

      assert %{mount: "C:\\", total_bytes: 104_857_600, free_bytes: 41_943_040, percent: 60} =
               Storage.windows_volume("C:\\Users\\someone\\data", volumes)
    end

    test "does not care how the drive is spelt or which separator the path uses" do
      volumes = [{~c"D:\\", 200 * 1024, 150 * 1024, 25}]

      assert %{mount: "D:\\"} = Storage.windows_volume("d:/data/runs", volumes)
    end

    test "answers nothing for a drive the table does not list" do
      assert Storage.windows_volume("Z:\\data", [{~c"C:\\", 100 * 1024, 40 * 1024, 60}]) == nil
    end

    test "answers nothing for a path that names no drive" do
      assert Storage.windows_volume("\\\\server\\share\\data", [{~c"C:\\", 1, 1, 1}]) == nil
    end

    test "answers nothing when the table has no room to report" do
      assert Storage.windows_volume("C:\\data", [{~c"none", 0, 0, 0}]) == nil
    end
  end
end
