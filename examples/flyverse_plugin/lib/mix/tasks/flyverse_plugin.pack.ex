defmodule Mix.Tasks.FlyversePlugin.Pack do
  @shortdoc "Writes the four-neuron demonstrator pack"

  @moduledoc """
  Writes flyverse's demonstrator connectome into `directory`.

      mix flyverse_plugin.pack /tmp/flyverse-demo
      FLYVERSE_PACK=/tmp/flyverse-demo mix run --no-halt

  The pack is four neurons in flyverse's own format, opened by flyverse's own
  loader (`FlyversePlugin.Pack` says why this example ships a writer rather than
  150 MB of dataset). It is not a fly: nothing in it came from a connectome, and
  a behaviour that follows from it is a statement about the wiring this task
  wrote.
  """

  use Mix.Task

  @impl true
  def run([directory]) do
    Mix.Task.run("compile")

    case FlyversePlugin.Pack.write(directory, FlyversePlugin.Demonstrator.spec()) do
      {:ok, %{neurons: neurons, edges: edges}} ->
        verify(directory)
        Mix.shell().info("wrote #{neurons} neurons and #{edges} edges to #{directory}")

      {:error, sentence} ->
        Mix.raise(sentence)
    end
  end

  def run(_arguments) do
    Mix.raise("usage: mix flyverse_plugin.pack <directory>")
  end

  # The pack is opened by the engine before the task says it succeeded: a writer
  # whose output the reader refuses has not written a pack.
  defp verify(directory) do
    case FlyversePlugin.Native.open(directory) do
      {:ok, connectome} ->
        {neurons, edges} = FlyversePlugin.Native.census(connectome)
        Mix.shell().info("the engine reads it back: #{neurons} neurons, #{edges} edges")

      {:error, {code, sentence}} ->
        Mix.raise("the engine refuses the pack it was just given (#{code}): #{sentence}")
    end
  end
end
