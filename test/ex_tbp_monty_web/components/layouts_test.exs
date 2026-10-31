defmodule ExTbpMontyWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ExTbpMontyWeb.Layouts

  @repo "https://github.com/d-led/ex.tbp.monty"
  @run "https://github.com/d-led/ex.tbp.monty/actions/runs/42"

  # What an image pushed from main carries: the ref it was built from, the
  # commit, and the run that built it.
  @released %{
    version: "main",
    revision: "3f2a1c9d4e5f",
    built_at: "2026-10-27T12:00:00Z",
    ci: %{provider: "github", workflow: "ci", run_number: "42", run_url: @run}
  }

  # A checkout nobody has built: `mix phx.server` on a laptop.
  @checkout %{version: "dev", revision: nil, built_at: nil, ci: nil}

  defp footer(build, opts \\ []) do
    render_component(&Layouts.footer/1, build: build, repo: Keyword.get(opts, :repo, @repo))
  end

  describe "footer/1 and the build it reports" do
    test "a build says the ref it was built from and the short commit" do
      html = footer(@released)

      assert html =~ ~s(id="build-info")
      assert html =~ "main+3f2a1c9"
    end

    test "its tooltip says everything the build knows about itself" do
      html = footer(@released)

      assert html =~ "version main, commit 3f2a1c9, built 2026-10-27T12:00:00Z, #{@run}"
    end

    test "a build that came from a pipeline links the run that produced it" do
      html = footer(@released)

      assert html =~ ~s(href="#{@run}")
      assert html =~ "ci #42"
    end

    test "a build assembled by hand links no run, and still names its commit" do
      html = footer(%{@released | ci: nil})

      assert html =~ "main+3f2a1c9"
      refute html =~ "actions/runs"
    end

    test "a checkout that no build touched says dev, and claims no run" do
      html = footer(@checkout)

      assert html =~ ~s(title="version dev")
      assert html =~ ">dev<"
      refute html =~ "actions/runs"
    end
  end

  describe "footer/1 and the source link" do
    test "the octocat leads to the repository, under a label a screen reader can read" do
      html = footer(@released)

      assert html =~ ~s(id="source-repo")
      assert html =~ ~s(href="#{@repo}")
      assert html =~ ~s(aria-label="Source code on GitHub")
    end

    test "a fork that configures no repository shows no octocat" do
      html = footer(@released, repo: nil)

      refute html =~ ~s(id="source-repo")
    end
  end
end
