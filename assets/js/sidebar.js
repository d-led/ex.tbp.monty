// The sidebar: a column beside the content on a laptop, a drawer on a phone.
//
// The markup is server-rendered and usable as-is, so nothing here is needed for
// the page to work. This module adds three things the markup cannot: the
// remembered collapse preference, the drawer's backdrop and Escape handling, and
// the current page marked in the list.
//
// Everything is delegated from `document` and looked up on demand, so a LiveView
// navigation that re-renders the sidebar needs no re-initialisation.

const STORAGE_KEY = "ex_tbp_monty:sidebar";
const DESKTOP_QUERY = "(min-width: 1024px)";
const BREAKPOINTS = window.matchMedia(DESKTOP_QUERY);

const state = {open: false, collapsed: readCollapsed()};

// Opening the column for somebody else — the walkthrough points at items in it,
// and a step aimed at a collapsed rail or a closed drawer is a step aimed at
// nothing. Not remembered: the preference a person set is theirs to keep.
export function revealSidebar() {
  state.open = true;
  state.collapsed = false;
  render();
}

function elements() {
  return {
    aside: document.getElementById("app-sidebar"),
    backdrop: document.querySelector("[data-sidebar-backdrop]"),
    toggle: document.querySelector("[data-sidebar-toggle]"),
  };
}

function readCollapsed() {
  try {
    return window.localStorage.getItem(STORAGE_KEY) === "collapsed";
  } catch (_error) {
    return false;
  }
}

function rememberCollapsed() {
  try {
    window.localStorage.setItem(STORAGE_KEY, state.collapsed ? "collapsed" : "expanded");
  } catch (_error) {
    // Private browsing: the preference simply does not persist.
  }
}

const onDesktop = () => BREAKPOINTS.matches;

function render() {
  const {aside, backdrop, toggle} = elements();
  if (!aside) return;

  const desktop = onDesktop();
  const visible = desktop ? !state.collapsed : state.open;

  aside.toggleAttribute("data-open", state.open);
  // Only a desktop collapses: on a phone the drawer is always the full width.
  aside.toggleAttribute("data-collapsed", desktop && state.collapsed);
  // Off-screen must also mean out of the tab order and out of the a11y tree.
  aside.inert = !visible;
  if (backdrop) backdrop.hidden = !(state.open && !desktop);
  document.body.classList.toggle("overflow-hidden", state.open && !desktop);
  if (toggle) toggle.setAttribute("aria-expanded", String(visible));
}

// Which page this is, read from the address rather than passed in: the sidebar
// is shared by every page, and a navigation that changes the address is exactly
// when the marking has to change.
function mark() {
  const path = window.location.pathname;

  for (const link of document.querySelectorAll("[data-nav]")) {
    const href = link.getAttribute("href") || "";
    // `/` is only itself; everything else also owns what hangs below it, so a
    // run's page still lights up Runs.
    const current = href === "/" ? path === "/" : path === href || path.startsWith(href + "/");
    link.toggleAttribute("data-active", current);
    if (current) {
      link.setAttribute("aria-current", "page");
    } else {
      link.removeAttribute("aria-current");
    }
  }
}

document.addEventListener("click", event => {
  const toggle = event.target.closest("[data-sidebar-toggle]");
  if (toggle) {
    if (onDesktop()) {
      state.collapsed = !state.collapsed;
      rememberCollapsed();
    } else {
      state.open = !state.open;
    }
    render();
    return;
  }

  if (event.target.closest("[data-sidebar-backdrop]")) {
    state.open = false;
    render();
    return;
  }

  // Following a link inside the drawer closes it; otherwise the page underneath
  // arrives with the drawer still over it.
  if (event.target.closest("#app-sidebar a") && !onDesktop()) {
    state.open = false;
    render();
  }
});

document.addEventListener("keydown", event => {
  if (event.key === "Escape" && state.open && !onDesktop()) {
    state.open = false;
    render();
  }
});

BREAKPOINTS.addEventListener("change", render);
window.addEventListener("phx:page-loading-stop", mark);

render();
mark();
