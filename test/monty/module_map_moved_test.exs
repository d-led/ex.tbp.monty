defmodule Monty.ModuleMapMovedTest do
  @moduledoc """
  The map describes a checkout at a commit, so a checkout that has moved is
  something a reader has to be told about.

  The check shells out to git, which is why it is specified here against a
  throwaway repository rather than against this workspace's checkout: what a
  package is *at* is a fact about the machine, and a test that asked the real
  checkout would report whatever happened to be pulled when it ran.
  """

  use ExUnit.Case, async: false

  alias Monty.ModuleMap
  alias Monty.Test.Tmp

  test "names a package whose checkout has moved away from the recorded commit" do
    root = git_checkout()

    Tmp.app_env(:monty_source, root)
    Tmp.app_env(:teleop_source, root)

    assert [{"monty", recorded, current} | _more] = ModuleMap.moved()

    assert recorded == ModuleMap.sources()["monty"]["commit"]
    assert current != recorded
    # What git answered, not what this test made up: the commit it just created.
    assert current == head(root)
  end

  test "says nothing about a package with no checkout to ask" do
    # A directory that is not a repository has no commit, and a package unpacked
    # from an archive is not a package that has drifted.
    root = Tmp.dir("not-a-checkout")

    Tmp.app_env(:monty_source, root)
    Tmp.app_env(:teleop_source, root)

    assert ModuleMap.moved() == []
  end

  # A checkout with one commit, which cannot be the recorded one: the map's
  # commits are Hex-length hashes of Monty's own history.
  defp git_checkout do
    root = Tmp.dir("checkout")

    File.write!(Path.join(root, "README.md"), "a checkout\n")

    git!(root, ~w(init --quiet))
    git!(root, ~w(add README.md))
    git!(root, ~w(-c user.name=test -c user.email=test@example.com commit --quiet -m one))

    root
  end

  defp head(root), do: git!(root, ~w(rev-parse HEAD))

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
