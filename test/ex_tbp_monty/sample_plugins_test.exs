defmodule ExTbpMonty.SamplePluginsTest do
  @moduledoc """
  The seam a page uses, and the one answer every build but the window gives.

  The sample plugin nodes are a *window's*: only the desktop bundle carries their
  releases, and only a window runs on the machine a person is sitting at. So the
  page asks a module that a build names in configuration, and a server build
  answers "this build carries none" rather than pretending or crashing.
  """
  use ExUnit.Case, async: false

  alias ExTbpMonty.SamplePlugins
  alias Monty.Test.Tmp

  # A build that carries them, in the only way a page can tell the difference.
  defmodule Carries do
    @behaviour ExTbpMonty.SamplePlugins

    @impl true
    def available?, do: true

    @impl true
    def start, do: {:ok, ["example_plugin@127.0.0.1"]}

    @impl true
    def stop, do: :ok
  end

  setup do
    Tmp.without_app_env(:sample_plugins)
    :ok
  end

  test "a build with no sample plugins says so, and starts nothing" do
    refute SamplePlugins.available?()
    assert {:error, sentence} = SamplePlugins.start()
    assert sentence =~ "carries no sample plugin nodes"
    assert SamplePlugins.stop() == :ok
  end

  test "a build that carries them is the one asked" do
    Application.put_env(:ex_tbp_monty, :sample_plugins, Carries)
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :sample_plugins) end)

    assert SamplePlugins.available?()
    assert SamplePlugins.start() == {:ok, ["example_plugin@127.0.0.1"]}
    assert SamplePlugins.stop() == :ok
  end
end
