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

  Anything the test starts that writes into this directory has to be finished
  with it before the test ends, and stopping the process is not always enough:
  `start_supervised/2` stops a child only when the *next* test starts, and a
  database closed while in WAL mode finalises its journal once its memory is
  collected, which is later still. Either one writes back into a directory that
  has just been removed, and the removal fails with "file already exists".
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
  A shell environment variable unset for this test, and put back as it was.

  "Unset" is not "set to an empty string": code that asks whether a variable is
  there gets `nil` from one and `""` from the other, and the difference is the
  whole point of a test that says *nothing is configured*.
  """
  @spec without_env(String.t()) :: :ok
  def without_env(name) do
    previous = System.get_env(name)
    System.delete_env(name)

    ExUnit.Callbacks.on_exit(fn -> restore_system_env(name, previous) end)
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

  @doc """
  An application setting unset for this test, and put back as it was.

  The counterpart of `without_env/1`: a key that is absent is what a release
  that configures nothing looks like, and that is the state some decisions are
  only correct in.
  """
  @spec without_app_env(atom()) :: :ok
  def without_app_env(key) do
    previous = Application.fetch_env(:ex_tbp_monty, key)
    Application.delete_env(:ex_tbp_monty, key)

    ExUnit.Callbacks.on_exit(fn -> restore_app_env(key, previous) end)
  end

  @doc """
  A library tree a test may write into, answering what the installed one answers.

  A run that trains files its memory in the library tree, and a test that trained
  into the checkout's tree would leave libraries the next config to name one of
  those models would trust. Pointing the suite at an empty tree instead is the
  opposite mistake: a config whose model this application ships would then be
  asked to recognise objects from no memory at all.

  So every release the checkout carries is a directory of symlinks to the same
  files — 185 MB is not copied — and `trained/` is a real, empty directory: that
  is the one release a run writes (`Monty.Studio.Learned` files every memory it
  keeps under it), so a test's memory lands in the temporary tree and a memory
  the application ships is never written through a link.
  """
  @spec libraries(String.t()) :: Path.t()
  def libraries(prefix \\ "libraries") do
    # Before the setting moves: what the checkout carries is what is mirrored.
    carried = carried_libraries()
    dir = env_dir(prefix, :monty_libraries_dir)
    trained = Path.join(dir, "trained")

    File.mkdir_p!(trained)

    for release_dir <- Path.wildcard(Path.join(carried, "*")),
        File.dir?(release_dir),
        release = Path.basename(release_dir),
        release != "trained",
        file <- Path.wildcard(Path.join(release_dir, "*")) do
      link = Path.join([dir, release, Path.basename(file)])

      File.mkdir_p!(Path.dirname(link))
      File.ln_s(Path.expand(file), link)
    end

    dir
  end

  defp carried_libraries do
    Application.get_env(:ex_tbp_monty, :monty_libraries_dir) ||
      Path.join(:code.priv_dir(:ex_tbp_monty), "monty/libraries")
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:ex_tbp_monty, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:ex_tbp_monty, key)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
