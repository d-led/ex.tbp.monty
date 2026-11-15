defmodule Monty.Test.CarriesPlugins do
  @moduledoc """
  A build that carries the two sample plugin nodes, in the only way a page can
  tell the difference: `ExTbpMonty.SamplePlugins` asks whichever module the
  `:sample_plugins` setting names.

  Here rather than in a test file because two suites need it, and a module defined
  inside a test file exists only in a run that has loaded that file — which is a
  shard boundary, not a mistake anyone notices until CI splits the suite in four
  and the settings page dies on `available?/0 is undefined`.
  """

  @behaviour ExTbpMonty.SamplePlugins

  @impl true
  def available?, do: true

  @impl true
  def start, do: {:ok, ["example_plugin@127.0.0.1"]}

  @impl true
  def stop, do: :ok
end
