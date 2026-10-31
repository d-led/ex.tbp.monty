defmodule ExTbpMontyWeb.Tour do
  @moduledoc """
  The walkthrough a first-time visitor is offered, as data.

  It lives here rather than in `assets/js/tour.js` for one reason: a step names
  a selector, and a selector that has been renamed is a tour that silently drops
  a step. Keeping the steps beside the pages they describe lets a test hold
  every selector to the rendered page.

  `driver.js` (MIT) draws these; the browser remembers what it has shown under
  `seen_key/0`, and `?tour=1` overrides that memory for anyone who wants it
  again.
  """

  @seen_key "ex_tbp_monty.tour.v1"

  @steps [
    %{
      element: "#app-sidebar",
      popover: %{
        title: "Everything is here",
        description:
          "Five places: the experiments Monty ships, the builder, the data and models, " <>
            "what ran, and the same studio answered over MCP. The toggle beside the title " <>
            "collapses this column to icons."
      }
    },
    %{
      element: "#intro",
      popover: %{
        title: "Monty, every experiment",
        description:
          "This is the index of Monty's own configurations. Nothing here has run yet: " <>
            "it is what can be run, and how each one is wired."
      }
    },
    %{
      element: "#experiment-search",
      popover: %{
        title: "Search",
        description: "Narrow by experiment name or by a component it uses."
      }
    },
    %{
      element: "#facets",
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
      popover: %{
        title: "Open one",
        description:
          "An experiment's page shows its sensors, learning modules, the connections " <>
            "between them and the config behind them, before anything runs."
      }
    },
    %{
      element: "#nav-build",
      popover: %{
        title: "Build one",
        description:
          "Compose a new config from Monty's own options, with the checks Monty " <>
            "would make."
      }
    },
    %{
      element: "#nav-prerequisites",
      popover: %{
        title: "Data and models",
        description:
          "The training data and model bundles are not in the container. That page " <>
            "downloads them into the running instance, or explains mounting your own."
      }
    },
    %{
      element: "#nav-mcp",
      popover: %{
        title: "Ask from an editor",
        description:
          "The same application answers an assistant over MCP. That page has the " <>
            "endpoint and the configuration to paste into an editor."
      }
    },
    %{
      element: "#build-info",
      popover: %{
        title: "Which build is this",
        description: "The footer names the commit, and links to its source and its CI run."
      }
    }
  ]

  @doc "Where the browser records that the tour has been shown."
  def seen_key, do: @seen_key

  @doc "The steps, in order, as `driver.js` expects them."
  def steps, do: @steps

  @doc "The steps as the JSON a page hands to the hook."
  def payload, do: Phoenix.json_library().encode!(@steps)
end
