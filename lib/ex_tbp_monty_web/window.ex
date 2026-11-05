defmodule ExTbpMontyWeb.Window do
  @moduledoc """
  Whether this server is the sidecar of a desktop window.

  `src-tauri/src/main.rs` sets `EX_TBP_MONTY_WINDOW=1` in the environment of the
  release it starts, and that is the only thing that tells the two apart: the
  same code serves a browser and a window, deliberately, so a screen that only
  works in one of them is a screen that works in neither.

  Two things follow from the answer. The server stops with the window — the
  window holds its standard input open for as long as it runs, and the pipe
  closing is the window being gone (`ExTbpMonty.Desktop.Application`). And the
  window is the one place a page reports what it drew, to `/__painted`, which is
  what `scripts/smoke-window.sh` asks; on a deployment there is no report and the
  route does not exist.

  Read at request time, not at compile time: the same release answers both ways,
  and which one it is was decided by the process that started it.
  """

  @doc "True when this process was started by the desktop window."
  @spec mode?() :: boolean()
  def mode?, do: System.get_env("EX_TBP_MONTY_WINDOW") == "1"
end
