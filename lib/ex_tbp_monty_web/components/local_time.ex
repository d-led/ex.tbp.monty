defmodule ExTbpMontyWeb.LocalTime do
  @moduledoc """
  A moment, stamped for the person reading it.

  The server knows a run happened at an instant in UTC; the reader compares it
  with their own clock and their own calendar. So the instant travels as a
  `<time datetime>` — machine-readable, and the same text for anything that
  parses the page — and the colocated hook rewrites the visible text into the
  browser's zone. Until it does, the fallback is the UTC stamp with `UTC` after
  it, so a page read without JavaScript is still right about *when*.

  Two shapes, because they answer two questions: `:stamp` is which run this was
  (`2026-11-01 16:20`), and `:clock` is where in a run a line falls
  (`16:20:03`).

  The hook goes on the container that holds the times, not on each `<time>`: a
  log of two thousand lines is two thousand elements and one hook.

  Its name is written out in full wherever it is used (`hook_name/0`), because a
  bare `.LocalTime` is resolved against the module whose *template* carries the
  attribute — `ExTbpMontyWeb.ExperimentLive.LocalTime`, which does not exist. The
  hook is defined here, so the attribute has to say so.
  """

  use Phoenix.Component

  @hook "ExTbpMontyWeb.LocalTime.LocalTime"

  @doc "The registered name of the hook, for the `phx-hook` of a container."
  @spec hook_name() :: String.t()
  def hook_name, do: @hook

  attr :at, :any, required: true
  attr :style, :atom, values: [:stamp, :clock], default: :stamp
  attr :class, :string, default: nil

  def local_time(assigns) do
    assigns = assign(assigns, :instant, instant(assigns.at))

    ~H"""
    <time
      :if={@instant}
      datetime={@instant}
      title={@instant}
      class={@class}
      data-local-time={@style}
    >
      {fallback(@instant, @style)}
    </time>
    <span :if={!@instant} class={@class}>unknown</span>
    """
  end

  @doc """
  The hook that localises every `<time data-local-time>` under its element.

  Rendered once per container, and it runs again after every patch, because a
  live log keeps appending lines while it is read.
  """
  def local_time_hook(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      // A time is stamped in UTC because that is what a server knows. The
      // reader's clock is what they compare it to, and only the browser knows
      // that zone, so each `<time>` is rewritten here — on mount and again after
      // every patch.
      export default {
        mounted() {
          this.localise()
        },

        updated() {
          this.localise()
        },

        localise() {
          for (const node of this.el.querySelectorAll("time[datetime]")) {
            const at = new Date(node.getAttribute("datetime"))
            if (Number.isNaN(at.getTime())) continue

            node.textContent =
              node.dataset.localTime === "clock"
                ? at.toLocaleTimeString(undefined, {
                    hour: "2-digit",
                    minute: "2-digit",
                    second: "2-digit",
                  })
                : at.toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" })

            node.title = at.toLocaleString()
          }
        },
      }
    </script>
    """
  end

  defp instant(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp instant(%{} = at), do: Map.get(at, :instant)
  defp instant(text) when is_binary(text), do: text
  defp instant(_absent), do: nil

  defp fallback(instant, :clock), do: strftime(instant, "%H:%M:%S UTC")
  defp fallback(instant, :stamp), do: strftime(instant, "%Y-%m-%d %H:%M UTC")

  defp strftime(instant, format) do
    case DateTime.from_iso8601(instant) do
      {:ok, at, _offset} -> Calendar.strftime(at, format)
      _not_a_moment -> instant
    end
  end
end
