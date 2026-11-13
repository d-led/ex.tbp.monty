defmodule ExTbpMonty.NodeTest do
  @moduledoc """
  What the node module promises: the answer to "am I in a cluster" is the VM's
  answer, and a node that is not says what would make it one.
  """
  use ExUnit.Case, async: true

  alias ExTbpMonty.Node

  test "the answer is the VM's own, not a setting" do
    assert Node.distributed?() == (node() != :nonode@nohost)
    assert Node.name() == node()
  end

  test "a node with no name is told the variable and the command line" do
    if Node.distributed?() do
      assert Node.why_not() == nil
    else
      assert Node.why_not() =~ "was not started with a name"
      assert Node.why_not() =~ "NODE_NAME"
      assert Node.why_not() =~ "elixir --sname monty"
    end
  end

  test "the peers are the VM's peers" do
    # `:erlang.nodes/0` rather than `Node.list/0`: inside this module `Node` names
    # the module under test, and a test that reached the real one through the alias
    # would be asserting that a function calls itself.
    assert Node.peers() == :erlang.nodes()
  end

  test "the settings report unset variables as unset, not as defaults" do
    settings = Node.settings()

    assert Map.has_key?(settings, "NODE_NAME")
    assert Map.has_key?(settings, "PLUGIN_SCOPE")

    if System.get_env("PLUGIN_SCOPE") == nil do
      assert settings["PLUGIN_SCOPE"] == nil
    end
  end

  describe "a node name as a directory name" do
    test "is the name with everything a path cannot hold replaced" do
      # A node is `name@host`, and a Windows path cannot hold the `:` a long name
      # carries at all — so the folder name is one segment everywhere, and still
      # reads as the node.
      assert Node.safe_name(:"monty@127.0.0.1") == "monty_127.0.0.1"
      assert Node.safe_name(:"monty2@192.168.1.7") == "monty2_192.168.1.7"
      assert Node.safe_name("monty@fe80::1") == "monty_fe80__1"
      assert Node.safe_name(:monty) == "monty"
    end
  end

  # A node name is not a URL, and a page that says "the run is on node2" has to
  # give a reader somewhere to click: the host is the one its peers dialled, the
  # port is the one the endpoint was configured with.
  describe "the address a node answers on" do
    test "is the host of its own name, on the port the endpoint was given" do
      port =
        :ex_tbp_monty |> Application.get_env(ExTbpMontyWeb.Endpoint, []) |> get_in([:http, :port])

      assert Node.web_url(:"monty@127.0.0.1") == "http://127.0.0.1:#{port}"
      assert Node.web_url(:"monty2@10.0.0.7") == "http://10.0.0.7:#{port}"
    end

    test "is nothing at all for a node nobody could dial" do
      # A node that was never given a name has no address, and inventing one
      # would be a link that leads nowhere.
      assert Node.web_url() == nil
      assert Node.web_url(:nonode@nohost) == nil
      assert Node.web_url(:monty) == nil
    end
  end
end
