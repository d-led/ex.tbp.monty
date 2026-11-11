// Keys, as the keys a page acts on rather than the keys a keyboard emits.
//
// `KeyboardEvent.key` is "Escape" in every current browser, "Esc" in the older
// ones, and there are setups — a remapped keyboard, an extension, an embedded
// view — where `key` arrives as "Unidentified" while the deprecated `keyCode`
// still says 27. A key that leaves full screen should not depend on which of
// those a reader's machine happens to report.

export const isEscape = (event) =>
  event.key === "Escape" || event.key === "Esc" || event.keyCode === 27;
