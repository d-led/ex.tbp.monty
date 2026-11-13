defmodule Mix.Tasks.FlyversePlugin.Engine do
  @shortdoc "Builds the Rust engine into priv/native"

  @moduledoc """
  Builds `native/flyverse_nif` and puts the library where `Rustler` looks.

  `mix compile` runs this first, so the example is buildable by `mix deps.get`
  and nothing else.

  ## Why a task and not the compiler

  `use Rustler` builds the crate **when the module is compiled** — and the
  module is not recompiled when only the Rust sources change, nor at all when
  the artefact is deleted while `_build` still holds a current beam. That second
  case is not hypothetical: `priv/native` is ignored by git, so any `git clean`
  removes the engine while `mix` still believes the project is up to date, and
  every call then raises `function FlyversePlugin.Native.open/1 is undefined
  (module FlyversePlugin.Native is not available)`. The engine was missing
  exactly like that when a plugin host came up offering nothing.

  So the rule here is the artefact's own: build when it is absent, or older than
  the crate. `Rustler.Compiler` does the build, because the library name, the
  destination and the `_build` copy are its business and not this task's.
  """

  use Mix.Task

  @crate "flyverse_nif"

  @impl true
  def run(_arguments) do
    artefact = artefact_path()

    if stale?(artefact) do
      refuse_without_cargo!()

      Rustler.Compiler.compile_crate(
        :flyverse_plugin,
        [],
        otp_app: :flyverse_plugin,
        crate: @crate
      )

      unless File.exists?(artefact) do
        Mix.raise(
          "the engine was built and #{artefact} is still not there — " <>
            "Rustler put it somewhere this task does not know about"
        )
      end
    end
  end

  @doc """
  Where the BEAM expects the engine, in the project rather than in `_build`.

  The extension is the one `:erlang.load_nif/2` appends: a shared object on the
  Unixes and a DLL on Windows.
  """
  @spec artefact_path() :: Path.t()
  def artefact_path do
    Path.join([project_root(), "priv", "native", @crate <> extension()])
  end

  defp extension, do: if(match?({:win32, _}, :os.type()), do: ".dll", else: ".so")

  defp stale?(artefact) do
    case File.stat(artefact, time: :posix) do
      {:error, _reason} -> true
      {:ok, %{mtime: built}} -> newest_source() > built
    end
  end

  defp newest_source do
    root = project_root()

    [
      "native/#{@crate}/src/**/*.rs",
      "native/#{@crate}/Cargo.toml",
      "native/#{@crate}/Cargo.lock"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.map(fn file -> File.stat!(file, time: :posix).mtime end)
    |> Enum.max(fn -> 0 end)
  end

  defp refuse_without_cargo! do
    if System.find_executable("cargo") == nil do
      Mix.raise(
        "the engine is built with cargo and there is no cargo on the PATH: " <>
          "install a Rust toolchain, then `mix compile` again"
      )
    end
  end

  defp project_root, do: Mix.Project.project_file() |> Path.dirname()
end
