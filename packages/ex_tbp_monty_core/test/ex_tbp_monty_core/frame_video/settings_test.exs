defmodule ExTbpMonty.Core.FrameVideo.SettingsTest do
  # The encoding parameters are data, not constants: what a benchmark sweeps and
  # what a node changes without a release. These describe the two ways a caller
  # gets at them — overrides and the application's config — and the values a
  # codec cannot accept.

  # Not async: the application's config is one in this VM, and the last test sets
  # it deliberately.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Core.FrameVideo.Settings

  setup do
    on_exit(fn -> Application.delete_env(:ex_tbp_monty_core, :frame_video) end)
  end

  test "the defaults are the studio's, and a caller may override any of them" do
    assert %Settings{fps: 20, qp: 18, gop: 60, bitrate: 0} = Settings.new()
    assert %Settings{qp: 30, gop: 12} = Settings.new(qp: 30, gop: 12)
  end

  test "a node changes them in its config, and an override still wins" do
    Application.put_env(:ex_tbp_monty_core, :frame_video, qp: 24, fps: 10)

    assert %Settings{qp: 24, fps: 10, gop: 60} = Settings.new()
    assert %Settings{qp: 26} = Settings.new(qp: 26)
  end

  test "a value a codec cannot take is refused where it is given" do
    assert_raise ArgumentError, ~r/fps must be a positive integer/, fn -> Settings.new(fps: 0) end

    assert_raise ArgumentError, ~r/qp must be between 0 and 51/, fn -> Settings.new(qp: 52) end

    assert_raise ArgumentError, ~r/gop must be a positive integer/, fn -> Settings.new(gop: 0) end
  end

  test "the native side gets them in one tuple, in one order" do
    assert Settings.to_nif(Settings.new(fps: 5, qp: 40, gop: 7, bitrate: 1000)) == {5, 40, 7, 1000}
  end
end
