defmodule Monty.Test.Tmp do
  @moduledoc """
  A place to write during a test, and the settings that point at it, gone when
  the test ends.

  A suite that touches a disk needs a name nothing else will take, the directory
  made, and the settings restored — five lines repeated in a dozen files, and one
  of them eventually forgetting the removal or the restore. Restoring is the part
  worth writing once: deleting a key is not the same as setting it to `nil`,
  because `Application.get_env/3` answers `nil` for a key that exists and is
  empty, and the caller's default never applies.

  Every function here registers its own `on_exit`, so a test says *why* it wants
  a directory and nothing about how one is made.
  """

  @doc """
  A fresh directory, removed with everything in it when the test ends.

  `prefix` names it in the system temporary directory, so a directory left behind
  by a crash is recognisable as this suite's.
  """
  @spec dir(String.t()) :: Path.t()
  def dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)

    path
  end

  @doc """
  A file name in a fresh directory, for the tests that need one file.

  Nothing is created: the caller writes the file, at the name it asked for.
  """
  @spec file(String.t()) :: Path.t()
  def file(name), do: Path.join(dir(Path.rootname(name)), name)

  @doc """
  A fresh directory that an application environment key points at for this test.
  """
  @spec env_dir(String.t(), atom()) :: Path.t()
  def env_dir(prefix, key) do
    path = dir(prefix)
    app_env(key, path)
    path
  end

  @doc """
  An application environment key set for this test, and put back as it was.

  Restored to its previous value, or deleted when it had none.
  """
  @spec app_env(atom(), term()) :: :ok
  def app_env(key, value) do
    previous = Application.fetch_env(:ex_tbp_monty, key)
    Application.put_env(:ex_tbp_monty, key, value)

    ExUnit.Callbacks.on_exit(fn -> restore_app_env(key, previous) end)
  end

  @doc """
  A shell environment variable set for this test, and put back as it was.
  """
  @spec system_env(String.t(), String.t()) :: :ok
  def system_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn -> restore_system_env(name, previous) end)
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:ex_tbp_monty, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:ex_tbp_monty, key)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
