defmodule ExTbpMontyWeb.ColocatedCSS do
  @moduledoc """
  Styles that belong to a component, kept beside it.

  A `<style :type={ExTbpMontyWeb.ColocatedCSS}>` in a template is extracted at
  compile time, concatenated into `priv/static/assets/css/app.css` through
  `phoenix-colocated/ex_tbp_monty/colocated.css`, and is therefore *global* CSS
  that happens to be written where the markup it styles is written.

  That is the right shape for the few rules Tailwind classes cannot express —
  a colour that arrives as data, a box positioned in reader pixels — without
  giving a component a class name in a stylesheet somewhere else that nobody
  would think to change with it.
  """

  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, _meta) do
    {:ok, css, []}
  end
end
