defmodule Mix.Tasks.Monty.Inputs do
  @shortdoc "Refreshes the copy of Monty's configs and snapshots in priv/monty"

  @moduledoc """
  Refreshes the copy of Monty this repository ships:

      mix monty.inputs              # update the checkout, then the copy
      mix monty.inputs --no-update  # copy the checkout exactly as it stands
      mix monty.inputs --check      # say whether the copy is current; write nothing

  `setup` runs it with `--warn-only`, so a first clone does not have to happen
  before the project can be worked on. Nothing it does is needed to compile or
  test — the copy is checked in — so a checkout it refuses to touch is a
  slowdown, not a broken build.

  ## What it refuses to do

  Updating a working copy of Monty is somebody else's work in progress, so this
  task only ever fast-forwards `main`, and only when the checkout is on `main`
  with nothing uncommitted. A checkout on a branch, a dirty tree, or a history
  that has diverged from `origin/main` is reported in full and left alone: the
  copy is not refreshed from a tree that is not what it claims to be.
  """

  use Mix.Task

  alias Monty.Config.{Inputs, Source}

  @switches [source: :string, update: :boolean, check: :boolean, warn_only: :boolean]

  @impl true
  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: @switches)
    root = source_root(options)

    cond do
      options[:check] -> check(root, options)
      options[:update] == false -> sync(root, options)
      true -> update_then_sync(root, options)
    end
  end

  defp source_root(options) do
    case options[:source] do
      nil ->
        Source.root()

      path ->
        root = Path.expand(path)
        Application.put_env(:ex_tbp_monty, :monty_source, root)
        root
    end
  end

  # -- modes ------------------------------------------------------------------

  defp check(root, options) do
    case Inputs.check(root) do
      {:ok, :current} ->
        Mix.shell().info("monty inputs: priv/monty is what #{root} would copy")

      {:ok, {:stale, counts}} ->
        refuse(
          "the copy in priv/monty is not what #{root} holds",
          """
          #{counts.stale} file(s) differ, #{counts.missing} are missing from the
          copy, #{counts.unexpected} are in the copy and not upstream.

          Run `mix monty.inputs --no-update` to refresh the copy, then look at
          `git diff priv/monty` — that diff is the review of the change.
          """,
          options
        )

      {:error, reason} ->
        refuse("cannot check the copy", inspect(reason), options)
    end
  end

  defp update_then_sync(root, options) do
    with :ok <- ensure_checkout(root, options),
         :ok <- ensure_clean_main(root, options),
         :ok <- fast_forward(root, options) do
      sync(root, options)
    end
  end

  defp sync(root, options) do
    case Inputs.sync(root) do
      {:ok, summary} ->
        Mix.shell().info(
          "monty inputs: copied monty@#{summary.monty} — #{summary.conf_files} configs, " <>
            "#{summary.snapshot_files} snapshots " <>
            "(+#{summary.added} new, #{summary.updated} changed, #{summary.removed} removed)"
        )

        if summary.added + summary.updated + summary.removed > 0 do
          Mix.shell().info("monty inputs: review with `git status --short priv/monty`")
        end

      {:error, {:missing, name, dir}} ->
        refuse("cannot copy Monty's configs", "no #{name} at #{dir}", options)
    end
  end

  # -- the checkout -----------------------------------------------------------

  defp ensure_checkout(root, options) do
    if File.exists?(Path.join(root, ".git")) do
      :ok
    else
      clone(root, options)
    end
  end

  defp clone(root, options) do
    Mix.shell().info("monty inputs: checking out tbp.monty into #{root} (first time)")

    File.mkdir_p!(Path.dirname(root))

    case System.cmd(
           "git",
           ["clone", "--depth", "1", "https://github.com/thousandbrainsproject/tbp.monty", root],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        refuse(
          "could not check out Monty into #{root}",
          output,
          options
        )
    end
  end

  defp ensure_clean_main(root, options) do
    with :ok <- on_main(root, options) do
      case git(root, ["status", "--porcelain"]) do
        "" ->
          :ok

        dirty ->
          refuse(
            "the Monty checkout at #{root} has uncommitted changes",
            """
            #{line_count(dirty)} file(s) are modified or untracked. Someone is working
            there, so this task will not move the branch out from under them, and
            will not copy a half-finished tree into priv/monty.

            Commit or stash it, or copy exactly what is there with
            `mix monty.inputs --no-update`.
            """,
            options
          )
      end
    end
  end

  defp on_main(root, options) do
    case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      "main" ->
        :ok

      branch ->
        refuse(
          "the Monty checkout at #{root} is on `#{branch}`, not `main`",
          """
          Only `main` is a statement about what Monty ships. The copy in
          priv/monty is untouched.

          Switch back with `git -C #{root} switch main`, or copy the branch's
          own configs with `mix monty.inputs --no-update`.
          """,
          options
        )
    end
  end

  defp fast_forward(root, options) do
    with :ok <- fetch(root, options) do
      case System.cmd("git", ["-C", root, "merge", "--ff-only", "origin/main"],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          :ok

        {output, _status} ->
          refuse(
            "the Monty checkout at #{root} cannot be fast-forwarded to origin/main",
            """
            #{output}

            It has commits of its own on `main`, so this task will not merge them.
            Reconcile the checkout yourself (rebase or reset), then run
            `mix monty.inputs` again — or copy what is there with
            `mix monty.inputs --no-update`.
            """,
            options
          )
      end
    end
  end

  defp fetch(root, options) do
    case System.cmd("git", ["-C", root, "fetch", "--quiet", "origin", "main"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        refuse(
          "could not fetch origin/main into #{root}",
          """
          #{output}

          Offline is not a problem: the copy in priv/monty is checked in and
          the build does not need this. Run `mix monty.inputs --no-update` to
          copy the checkout as it stands.
          """,
          options
        )
    end
  end

  # -- saying so --------------------------------------------------------------

  # A warning somebody can see while scrolling past, and an exit code that says
  # what happened. The answer is `:halt` in both cases: a refused update stops
  # this task — copying a tree it just declined to trust would be worse than not
  # copying — but `--warn-only` (what `setup` uses) leaves the build alone.
  defp refuse(headline, body, options) do
    banner = String.duplicate("=", 78)

    Mix.shell().error("""
    #{banner}
      MONTY INPUTS NOT UPDATED — #{headline}

    #{indent(body)}
    #{banner}
    """)

    if options[:warn_only] do
      Mix.shell().info("monty inputs: continuing — priv/monty is unchanged")
      :halt
    else
      Mix.raise("monty inputs: #{headline}")
    end
  end

  defp indent(body) do
    body
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &("      " <> &1))
  end

  defp line_count(text) do
    text |> String.split("\n", trim: true) |> length()
  end

  defp git(root, arguments) do
    case System.cmd("git", ["-C", root | arguments], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _status} -> Mix.raise("git #{Enum.join(arguments, " ")}: #{output}")
    end
  end
end
