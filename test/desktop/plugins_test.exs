defmodule ExTbpMonty.Desktop.PluginsTest do
  # The environment is the machine's, so these cannot run beside each other.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Desktop.Plugins
  alias Monty.Test.Tmp

  describe "the environment a sample plugin's launcher is started with" do
    test "is the child's own, not the RELEASE_* this window's VM carries" do
      # What a release VM has in its environment: every one of these describes
      # *this* release, and a launcher defaults a variable only while it is unset
      # or empty — so an inherited version number sends the child looking for a
      # folder that is not there, and it dies before printing a line.
      Tmp.system_env("RELEASE_VSN", "0.1.3")
      Tmp.system_env("RELEASE_NODE", "monty-studio-e2e")

      environment = environment()

      assert environment["RELEASE_VSN"] == ""
      assert environment["RELEASE_NODE"] == ""
    end

    test "gives the child the node to join and the cookie to join it with" do
      environment = environment()

      assert environment["MONTY_SEEDS"] == "monty-studio-abc@host"
      assert environment["RELEASE_COOKIE"] == cookie_of_this_node()
    end

    test "passes this node's cookie, not the one this VM was started with" do
      # Every release writes a `releases/COOKIE` of its own, and a peer answering
      # with a different one is refused — which arrives as "nothing happened".
      Tmp.system_env("RELEASE_COOKIE", "another-release-cookie")

      assert environment()["RELEASE_COOKIE"] == cookie_of_this_node()
    end
  end

  # A port takes the environment as charlists; the assertions read it as a map.
  defp environment do
    Plugins.environment("monty-studio-abc@host")
    |> Map.new(fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp cookie_of_this_node, do: Node.get_cookie() |> Atom.to_string()
end
