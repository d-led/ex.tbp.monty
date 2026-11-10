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
  attr :style, :atom, values: [:stamp, :clock, :elapsed], default: :stamp
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
          this.timer = setInterval(() => this.tick(), 1000)
        },

        destroyed() {
          clearInterval(this.timer)
        },

        updated() {
          this.localise()
        },

        // Only an interval moves an elapsed time: every clock on the page is a
        // statement that does not change, and rewriting them all a second at a
        // time is work nobody asked for.
        tick() {
          for (const node of this.el.querySelectorAll('time[data-local-time="elapsed"]')) {
            this.write(node)
          }
        },

        localise() {
          for (const node of this.el.querySelectorAll("time[datetime]")) {
            this.write(node)
          }
        },

        write(node) {
          const at = new Date(node.getAttribute("datetime"))
          if (Number.isNaN(at.getTime())) return

          const style = node.dataset.localTime

          node.textContent =
            style === "clock"
              ? at.toLocaleTimeString(undefined, {
                  hour: "2-digit",
                  minute: "2-digit",
                  second: "2-digit",
                })
              : style === "elapsed"
                ? this.elapsed(Date.now() - at.getTime())
                : at.toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" })

          node.title = at.toLocaleString()
        },

        // The two units a run is read in: a minute of stepping is minutes and
        // seconds, an hour of it is hours and minutes.
        elapsed(milliseconds) {
          const seconds = Math.max(0, Math.floor(milliseconds / 1000))
          if (seconds < 60) return `${seconds} s`

          const minutes = Math.floor(seconds / 60)
          if (minutes < 60) return `${minutes} m ${seconds % 60} s`

          return `${Math.floor(minutes / 60)} h ${minutes % 60} m`
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
  # How long ago is the reader's clock against the run's, and a snapshot of it
  # written by the server is wrong a second later. The reading without a script
  # is the instant itself, beside it.
  defp fallback(_instant, :elapsed), do: "…"

  defp strftime(instant, format) do
    case DateTime.from_iso8601(instant) do
      {:ok, at, _offset} -> Calendar.strftime(at, format)
      _not_a_moment -> instant
    end
  end
end
