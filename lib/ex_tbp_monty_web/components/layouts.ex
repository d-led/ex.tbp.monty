defmodule ExTbpMontyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ExTbpMontyWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-300 bg-base-100/80 backdrop-blur">
      <div class="mx-auto flex max-w-6xl flex-wrap items-center gap-2 px-4 py-2 sm:px-6 lg:px-8">
        <.link navigate={~p"/"} class="flex items-center gap-2 rounded-field px-1 py-1">
          <span class="grid size-8 place-items-center rounded-field bg-primary/15 text-primary">
            <.icon name="hero-cpu-chip-mini" class="size-5" />
          </span>
          <span class="text-sm font-semibold tracking-tight">Monty on the BEAM</span>
        </.link>

        <nav class="ms-auto flex flex-wrap items-center gap-1">
          <.nav_link navigate={~p"/"} label="Experiments" icon="hero-beaker-mini" />
          <.nav_link navigate={~p"/build"} label="Build" icon="hero-wrench-screwdriver-mini" />
          <.nav_link
            navigate={~p"/prerequisites"}
            label="Prerequisites"
            icon="hero-arrow-down-tray-mini"
          />
          <.nav_link navigate={~p"/runs/demo"} label="Runtime" icon="hero-play-mini" />
        </nav>
      </div>
    </header>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl space-y-6">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  One item in the application bar.
  """
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  def nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="btn btn-ghost btn-sm gap-1.5 font-normal">
      <.icon name={@icon} class="size-4 opacity-70" />
      {@label}
    </.link>
    """
  end
end
