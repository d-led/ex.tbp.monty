import { driver } from "driver.js";
import { revealSidebar } from "./sidebar";

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
    this.seenKey = this.el.dataset.seenKey;
    this.el.addEventListener("click", () => this.start());

    // Offered once per browser. Closing it early counts as having seen it: the
    // button is still there for anyone who wants it back.
    if (!localStorage.getItem(this.seenKey)) this.start();
  },

  start() {
    // The steps below name items in the column, and a column folded to a rail
    // would leave them pointing at icons. `revealSidebar` opens it — and on a
    // phone, where the column is a drawer that would cover the page, it does
    // nothing and those steps drop out through the filter below.
    revealSidebar();

    // Steps name a selector, and a page that does not have that element — or has
    // it off-screen, inside a drawer — would otherwise show a popover pointing
    // at nothing. Which page a visitor is on is the browser's to know, so the
    // filter lives here: the whole tour on the welcome page and the index, the
    // shell everywhere else.
    const steps = JSON.parse(this.el.dataset.steps || "[]").filter((step) =>
      onScreen(step.element),
    );

    if (steps.length === 0) return;

    driver({
      steps,
      showProgress: true,
      closeBtnLabel: "Close the tour",
      onDestroyed: () => localStorage.setItem(this.seenKey, "1"),
    }).drive();
  },
};

function onScreen(selector) {
  if (!selector) return false;

  const element = document.querySelector(selector);
  if (!element) return false;

  const box = element.getBoundingClientRect();

  // Width and left edge only: a target below the fold is fine — driver.js
  // scrolls to it — while one translated off the left edge is a drawer that is
  // closed, and pointing into it would highlight nothing.
  return box.width > 0 && box.right > 0 && box.left < window.innerWidth;
}
