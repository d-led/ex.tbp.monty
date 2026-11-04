defmodule ExTbpMonty.Desktop.ServerTest do
  # These read the shell's variables and hold a real socket, which is the
  # machine's, so they cannot run beside each other.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Desktop.Server
  alias Monty.Test.Tmp

  describe "the port the desktop app answers on" do
    test "is the same preferred one every launch, so a client pasted with it keeps working" do
      Tmp.without_env("MONTY_DESKTOP_PORT")
      settings = Tmp.file("desktop_port")

      assert Server.preferred_port(settings) == 42_800
      assert Server.choose_port(settings) == 42_800
    end

    test "is taken from the settings file when one names a port" do
      Tmp.without_env("MONTY_DESKTOP_PORT")
      settings = Tmp.file("desktop_port")
      # Written the way the notes spell a port, underscore and all.
      File.write!(settings, "42_910\n")

      assert Server.choose_port(settings) == 42_910
    end

    test "gives way to MONTY_DESKTOP_PORT, so a script can move it without editing a file" do
      Tmp.system_env("MONTY_DESKTOP_PORT", "42920")
      settings = Tmp.file("desktop_port")
      File.write!(settings, "42910")

      assert Server.choose_port(settings) == 42_920
    end

    test "ignores a setting that is not a port rather than refusing to start" do
      Tmp.without_env("MONTY_DESKTOP_PORT")
      settings = Tmp.file("desktop_port")
      File.write!(settings, "eighty")

      assert Server.choose_port(settings) == 42_800
    end

    test "falls back to one the operating system picks when the preferred one is held" do
      Tmp.without_env("MONTY_DESKTOP_PORT")
      settings = Tmp.file("desktop_port")

      held = hold_port()
      File.write!(settings, Integer.to_string(held))

      port = Server.choose_port(settings)

      assert port != held
      assert port_bindable?(port)
    end
  end

  # A second copy of the application is the case this exists for: something else
  # already has the port, and the copy still has to start.
  defp hold_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    port
  end

  defp port_bindable?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
