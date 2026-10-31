defmodule Monty.Studio.StorageTest do
  @moduledoc """
  The room left where this deployment writes, asked of the filesystem.

  The numbers belong to the machine the suite runs on, so what is held here is
  their shape and their relationships — a device with a total, free space inside
  it, and a mount that is a directory — rather than any particular figure.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Storage
  alias Monty.Test.Tmp

  describe "the volume behind a path" do
    test "answers with the device's own total, used and free space" do
      usage = Storage.usage(Tmp.dir("storage"))

      assert usage.path == Path.expand(usage.path)
      assert %{filesystem: filesystem, mount: mount} = usage.device
      assert filesystem != ""
      assert File.dir?(mount)

      assert %{total_bytes: total, used_bytes: used, free_bytes: free, percent: percent} =
               usage.device

      assert total > 0
      assert used >= 0 and used <= total
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
  end
end
