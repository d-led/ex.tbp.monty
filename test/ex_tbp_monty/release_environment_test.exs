defmodule ExTbpMonty.ReleaseEnvironmentTest do
  # `rel/env.sh.eex` is sourced by the release before the VM starts, so what it
  # exports is the window's node name — and that name is what a companion plugin
  # app dials. A name resolved through DNS is the failure this holds: on a
  # machine whose hostname resolves to an address the interface no longer has,
  # `monty-studio-<id>@<hostname>` is unreachable, the companion loops forever,
  # and neither side says anything.
  use ExUnit.Case, async: true

  @template Path.expand("../../rel/env.sh.eex", __DIR__)
  @windows_template Path.expand("../../rel/env.bat.eex", __DIR__)

  test "the desktop window is a node on the loopback, whatever the hostname resolves to" do
    environment =
      release_env(%{"EX_TBP_MONTY_WINDOW" => "1", "MONTY_STUDIO_INSTANCE_ID" => "abc123"})

    assert environment.node == "monty-studio-abc123@127.0.0.1"
    assert environment.distribution == "name"
    assert environment.erl_flags =~ "inet_dist_use_interface {127,0,0,1}"
  end

  test "a window told to stay out of a cluster is one undistributed node" do
    environment =
      release_env(%{
        "EX_TBP_MONTY_WINDOW" => "1",
        "MONTY_STUDIO_INSTANCE_ID" => "abc123",
        "MONTY_STUDIO_CLUSTER" => "0"
      })

    assert environment.distribution == "none"
  end

  test "a deployment that names its own node keeps that name" do
    environment =
      release_env(%{"EX_TBP_MONTY_WINDOW" => "1", "RELEASE_NODE" => "worker@10.0.0.7"})

    assert environment.node == "worker@10.0.0.7"
  end

  # The Windows template cannot be run here, and the comment above it says the
  # two files are kept identical on purpose: a window named on macOS and
  # unnamed on Windows is a cluster that half works.
  test "the Windows template names the window the same way" do
    template = File.read!(@windows_template)

    assert template =~ ~s(set "RELEASE_NODE=monty-studio-%MONTY_STUDIO_INSTANCE_ID%@127.0.0.1")
    assert template =~ ~s(set "RELEASE_DISTRIBUTION=name")
    assert template =~ "inet_dist_use_interface {127,0,0,1}"
  end

  defp release_env(variables) do
    assigns =
      Enum.map_join(variables, "\n", fn {name, value} -> "export #{name}='#{value}'" end)

    script = """
    unset FLY_APP_NAME POD_IP NODE_NAME RELEASE_NODE RELEASE_DISTRIBUTION ERL_AFLAGS
    unset MONTY_CLUSTER MONTY_STUDIO_CLUSTER MONTY_STUDIO_INSTANCE_ID EX_TBP_MONTY_WINDOW
    #{assigns}
    . #{@template} >/dev/null
    printf 'node=%s\ndistribution=%s\nflags=%s\n' "$RELEASE_NODE" "$RELEASE_DISTRIBUTION" "${ERL_AFLAGS:-}"
    """

    assert {said, 0} = System.cmd("sh", ["-c", script])
    [node, distribution, erl_flags] = String.split(said, "\n", trim: true)

    %{
      node: strip_label(node, "node="),
      distribution: strip_label(distribution, "distribution="),
      erl_flags: strip_label(erl_flags, "flags=")
    }
  end

  defp strip_label(line, label), do: String.replace_prefix(line, label, "")
end
