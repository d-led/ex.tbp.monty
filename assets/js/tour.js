import {driver} from "driver.js"

// The walkthrough the tour button starts. The steps come from the server
// (`ExTbpMontyWeb.Tour`), so their copy and their selectors sit beside the page
// they describe instead of in here.
//
// Two things matter for it to survive LiveView:
//
//   * the button carrying this hook is `phx-update="ignore"`, so patching the
//     page cannot pull it out from under the hook;
//   * driver.js appends its popovers to <body>, outside the LiveView tree, so a
//     patch does not delete them either.
export const StudioTour = {
  mounted() {
    this.seenKey = this.el.dataset.seenKey
    this.el.addEventListener("click", () => this.start())

    // Offered once per browser. Closing it early counts as having seen it: the
    // button is still there for anyone who wants it back.
    if (!localStorage.getItem(this.seenKey)) this.start()
  },

  start() {
    const steps = JSON.parse(this.el.dataset.steps || "[]")
    if (steps.length === 0) return

    driver({
      steps,
      showProgress: true,
      closeBtnLabel: "Close the tour",
      onDestroyed: () => localStorage.setItem(this.seenKey, "1"),
    }).drive()
  },
}
