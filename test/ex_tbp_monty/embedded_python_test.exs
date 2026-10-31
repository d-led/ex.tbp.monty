defmodule ExTbpMonty.EmbeddedPythonTest do
  # `:persistent_term` is not rolled back between tests, and neither are the
  # environment variables the wandb mode is read from.
  use ExUnit.Case, async: false

  alias ExTbpMonty.EmbeddedPython

  setup do
    EmbeddedPython.forget()
    on_exit(&EmbeddedPython.forget/0)
    :ok
  end

  describe "version/0" do
    test "the interpreter this build carries answers with its version" do
      assert {:ok, version} = EmbeddedPython.version()
      assert version =~ ~r/^\d+\.\d+/
    end

    test "the same answer comes back the second time" do
      {:ok, first} = EmbeddedPython.version()

      assert EmbeddedPython.version() == {:ok, first}
    end
  end

  describe "wandb_mode/0" do
    test "wandb's own default applies when nothing says otherwise" do
      set_wandb_mode(nil)

      assert EmbeddedPython.wandb_mode() == "online"
    end

    test "the environment wins, which is how the image turns wandb off" do
      set_wandb_mode("disabled")

      assert EmbeddedPython.wandb_mode() == "disabled"
    end

    test "an empty variable is no answer, not a mode called empty" do
      set_wandb_mode("")

      assert EmbeddedPython.wandb_mode() == "online"
    end
  end

  # `Tmp.system_env/2` puts a value; this has to take one away as well, because
  # "nothing is set" is what the default is about.
  defp set_wandb_mode(value) do
    previous = System.get_env("WANDB_MODE")

    if value,
      do: System.put_env("WANDB_MODE", value),
      else: System.delete_env("WANDB_MODE")

    on_exit(fn ->
      if previous,
        do: System.put_env("WANDB_MODE", previous),
        else: System.delete_env("WANDB_MODE")
    end)
  end
end
