defmodule ExTbpMontyWeb.Tour do
  @moduledoc """
  The walkthrough a first-time visitor is offered, as data.

  It lives here rather than in `assets/js/tour.js` for one reason: a step names
  a selector, and a selector that has been renamed is a tour that silently drops
  a step. Keeping the steps beside the pages they describe lets a test hold
  every selector to the rendered page.

  A step also says which page it describes. The `:shell` steps are the parts
  every page has — the header, the column, the footer; `:welcome` and `:index`
  describe one page each. The browser shows whichever of them the page it is on
  actually has, so the welcome page teaches the welcome page rather than a list
  of experiments the visitor has not opened yet.

  `driver.js` (MIT) draws these; the browser remembers what it has shown under
  `seen_key/0`, and the help button in the header shows it again.
  """

  @seen_key "ex_tbp_monty.tour.v1"

  @scopes [:shell, :welcome, :index]

  @steps [
    # The shell comes first and points at the toggle, not at the column: the
    # column is a drawer on a phone and a rail on a laptop, and only the button
    # that opens it looks the same in both.
    %{
      element: "#sidebar-toggle",
      scope: :shell,
      popover: %{
        title: "The way around",
        description:
          "Experiments, Build, Prerequisites, Runs and MCP. This button opens the column " <>
            "— a rail of icons on a laptop, a drawer over the page on a phone — and closes " <>
            "it again."
      }
    },
    %{
      element: "#app-sidebar",
      scope: :shell,
      popover: %{
        title: "Everything is here",
        description:
          "Five places: the experiments Monty ships, the builder, the data and models, " <>
            "what ran, and the same studio answered over MCP. The toggle above folds this " <>
            "column to icons. On a phone this column is a drawer, so this step is skipped " <>
            "there and the toggle above is the whole lesson."
      }
    },
    %{
      element: "#welcome-hero",
      scope: :welcome,
      popover: %{
        title: "Monty, on the BEAM",
        description:
          "The Thousand Brains Project's sensorimotor learning system, reimplemented " <>
            "module for module in Elixir, with a studio for looking inside a run."
      }
    },
    %{
      element: "#welcome-ways",
      scope: :welcome,
      popover: %{
        title: "Three ways in",
        description:
          "Read what Monty ships, compose a configuration of your own, or watch a run and " <>
            "the beliefs it forms step by step."
      }
    },
    %{
      element: "#welcome-first",
      scope: :welcome,
      popover: %{
        title: "Start with the tutorial",
        description:
          "Monty's own first experiment: one camera, one learning module. Open it, press " <>
            "Run, and read what the module thought it was touching."
      }
    },
    %{
      element: "#welcome-also",
      scope: :welcome,
      popover: %{
        title: "Data, models, and the other door",
        description:
          "A run reads Monty's config tree and its pretrained libraries; that page says " <>
            "what is here and what is still to download. MCP is the same studio, answered " <>
            "into an editor."
      }
    },
    %{
      element: "#intro",
      scope: :index,
      popover: %{
        title: "Monty, every experiment",
        description:
          "This is the index of Monty's own configurations. Nothing here has run yet: " <>
            "it is what can be run, and how each one is wired."
      }
    },
    %{
      element: "#experiment-search",
      scope: :index,
      popover: %{
        title: "Search",
        description: "Narrow by experiment name or by a component it uses."
      }
    },
    %{
      element: "#facets",
      scope: :index,
      popover: %{
        title: "Or narrow by shape",
        description:
          "Agent, module count, learning module and starting point. The counts respect " <>
            "each other, and the filters live in the URL, so a narrowed view can be " <>
            "bookmarked or passed on."
      }
    },
    %{
      element: "#experiments",
      scope: :index,
      popover: %{
        title: "Open one",
        description:
          "An experiment's page shows its sensors, learning modules, the connections " <>
            "between them and the config behind them, before anything runs."
      }
    },
    %{
      element: "#nav-build",
      scope: :shell,
      popover: %{
        title: "Build one",
        description:
          "Compose a new config from Monty's own options, with the checks Monty " <>
            "would make."
      }
    },
    %{
      element: "#nav-prerequisites",
      scope: :shell,
      popover: %{
        title: "Data and models",
        description:
          "Monty's config tree and the pretrained libraries it ships are in the " <>
            "container. The larger training and model bundles on that page are not — " <>
            "it downloads them into the running instance."
      }
    },
    %{
      element: "#nav-mcp",
      scope: :shell,
      popover: %{
        title: "Ask from an editor",
        description:
          "The same application answers an assistant over MCP. That page has the " <>
            "endpoint and the configuration to paste into an editor."
      }
    },
    %{
      element: "#build-info",
      scope: :shell,
      popover: %{
        title: "Which build is this",
        description: "The footer names the commit, and links to its source and its CI run."
      }
    },
    %{
      element: "#tour-start",
      scope: :shell,
      popover: %{
        title: "This walkthrough again",
        description: "It is offered once. This is the way back to it, on any page."
      }
    }
  ]

  @doc "Where the browser records that the tour has been shown."
  def seen_key, do: @seen_key

  @doc """
  The pages a step can describe: the shell every page has, and the pages
  themselves.
  """
  @spec scopes() :: [atom()]
  def scopes, do: @scopes

  @doc "The steps, in order, for every page at once."
  def steps, do: @steps

  @doc "The steps that describe one scope — the shell, or a page."
  @spec steps(atom()) :: [map()]
  def steps(scope) when scope in @scopes, do: Enum.filter(@steps, &(&1.scope == scope))

  @doc """
  The steps as the JSON a page hands to the hook.

  A step's scope stays here: it is how this file is tested against the pages,
  while the browser decides what to show by asking the DOM whether the element
  is there. Sending it would be a second, weaker copy of that question.
  """
  def payload do
    @steps
    |> Enum.map(&Map.take(&1, [:element, :popover]))
    |> Phoenix.json_library().encode!()
  end
end
