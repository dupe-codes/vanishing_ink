/**
 * JavaScript implementation of `client/ffi.gleam`.
 *
 * Gleam runtime encoding used in return values:
 * - `Ok(value)` / `Error(undefined)` — Gleam `Result(T, Nil)` variants,
 *   imported from the compiled prelude so they match the runtime classes
 *   the rest of the program expects.
 * - `toList(array)` — converts a JS array to a Gleam-runtime linked list.
 * - `#(a, b)` tuples are represented as two-element JS arrays `[a, b]`.
 */

import { Ok, Error as GleamError, toList } from "../gleam.mjs";

const PARAGRAPH_INDEX_ATTRIBUTE = "data-paragraph-global-index";
const WORD_INDEX_ATTRIBUTE = "data-global-index";
const RESIZE_DEBOUNCE_MS = 250;

// Single-slot module-level handle for the real-time fade engine's
// word timer. At most one timer is ever in flight; starting a new
// one clears any previous handle synchronously so a stray
// callback from an old run cannot fire after pause/stop. The slot
// returns the timeout id from `setTimeout` synchronously — unlike
// `lustre_animation`, which posts the id back via a follow-up
// microtask and leaves a cancellation gap. Clearing is also
// synchronous, so a `PauseFade` reducer arm that calls
// `clear_word_timer` is guaranteed to have stopped the in-flight
// callback before it returns.
let word_timer_id = null;

/** @returns {number} The viewport height in CSS pixels, read at call time. */
export function get_viewport_height() {
  return window.innerHeight;
}

/**
 * Returns the rendered height of the first element matching `selector`.
 * @param {string} selector CSS selector
 * @returns {Ok<number>|GleamError} `Ok(height)` in CSS pixels, or `Error(Nil)`
 *   when the selector matches no element.
 */
export function get_element_height(selector) {
  const el = document.querySelector(selector);
  if (el === null) {
    return new GleamError(undefined);
  }
  return new Ok(el.getBoundingClientRect().height);
}

/**
 * Measures all paragraphs inside `container_selector` by reading the
 * `data-paragraph-global-index` attribute on each descendant element and
 * recording its `getBoundingClientRect().height`.
 *
 * Accurate heights require the measured elements to use `display: flow-root`
 * (see `.page-paragraph` in `styles.css`) so inner margins are captured
 * rather than escaping the wrapper.
 *
 * @param {string} container_selector CSS selector for the measurement container
 * @returns {List} Gleam-encoded list of `[global_index, height]` pairs
 */
export function measure_paragraphs(container_selector) {
  const container = document.querySelector(container_selector);
  if (container === null) {
    return toList([]);
  }

  // The only producer of `data-paragraph-global-index` is
  // `int.to_string(global_index)` inside the Gleam view, so every
  // attribute value here is guaranteed to be a base-10 integer
  // string. No defensive `Number.isFinite` branch needed — Gleam's
  // static guarantees already exclude the failure mode.
  const nodes = container.querySelectorAll(`[${PARAGRAPH_INDEX_ATTRIBUTE}]`);
  const pairs = [];
  for (const node of nodes) {
    const index = Number.parseInt(node.getAttribute(PARAGRAPH_INDEX_ATTRIBUTE), 10);
    pairs.push([index, node.getBoundingClientRect().height]);
  }
  return toList(pairs);
}

/**
 * Walks every descendant of `container_selector` that carries a
 * `data-global-index` attribute, groups them by the y-coordinate of
 * their `getBoundingClientRect().top` (rounded to one CSS pixel), and
 * returns one `[top, height, first_gi, last_gi]` tuple per visual line
 * in document order. The `top` value is normalised to be relative to
 * the container — every entry's `top` equals the line's distance from
 * the container's top edge, so the caller can drop the tuple straight
 * onto an absolutely-positioned overlay anchored inside the container
 * without re-measuring.
 *
 * "Line" here means "set of word spans whose box tops align after
 * line-wrapping," which is what the reader visually perceives as one
 * row of text. Words that wrap across multiple visual lines are
 * impossible at the segmentation layer (one Word maps to one inline
 * span), so the per-word `getBoundingClientRect().top` is a faithful
 * proxy for line identity.
 *
 * Heights take the per-line maximum so a line that mixes a tall glyph
 * (e.g. ascender + descender) with shorter neighbours still reports a
 * pixel-accurate height for the active-line overlay.
 *
 * Returns an empty list when the selector matches no element or when
 * the container has no `data-global-index` descendants — the caller
 * treats both as "no lines to highlight."
 *
 * @param {string} container_selector CSS selector for the measurement container
 * @returns {List} Gleam-encoded list of `[top, height, first_gi, last_gi]` tuples
 */
export function measure_word_lines(container_selector) {
  const container = document.querySelector(container_selector);
  if (container === null) {
    return toList([]);
  }

  const container_top = container.getBoundingClientRect().top;
  const nodes = container.querySelectorAll(`[${WORD_INDEX_ATTRIBUTE}]`);

  // Group by integer-rounded viewport y so floating-point jitter at
  // sub-pixel widths cannot split a single line into two near-duplicate
  // bands. The Map keys the rounded viewport-relative y; each entry
  // carries the unrounded relative `top` (so the overlay reads a
  // crisp value, not the rounded one), the running max height, and
  // the lowest / highest word global index seen so far on this line.
  const lines = new Map();
  for (const node of nodes) {
    const rect = node.getBoundingClientRect();
    const key = Math.round(rect.top);
    const relative_top = rect.top - container_top;
    // `data-global-index` is produced by `int.to_string` in the Gleam
    // view, so every attribute value is a base-10 integer string —
    // no defensive `Number.isFinite` branch needed.
    const gi = Number.parseInt(node.getAttribute(WORD_INDEX_ATTRIBUTE), 10);

    const existing = lines.get(key);
    if (existing === undefined) {
      lines.set(key, {
        top: relative_top,
        height: rect.height,
        first_gi: gi,
        last_gi: gi,
      });
    } else {
      // Words inside the same line always arrive in document order
      // because `querySelectorAll` returns descendants in document
      // order — so `last_gi` is always the newest visit and
      // `first_gi` never needs updating after the line is first
      // seen. The `Math.max` on height handles a mixed-glyph line
      // where the first word reports a shorter bounding box than a
      // later one with a descender.
      existing.height = Math.max(existing.height, rect.height);
      existing.last_gi = gi;
    }
  }

  // Sort by viewport y so the returned list is in reading order. The
  // `Map` already preserves insertion order, but a defensive sort
  // keeps the contract independent of querySelectorAll's traversal
  // promise (which is the spec-defined "document order", but a future
  // shadow-DOM refactor could reshuffle).
  const sorted = [...lines.values()].sort((a, b) => a.top - b.top);
  return toList(sorted.map((l) => [l.top, l.height, l.first_gi, l.last_gi]));
}

/**
 * Installs a debounced `resize` listener on `window`. Uses a
 * trailing-edge debounce: the callback fires once, `RESIZE_DEBOUNCE_MS`
 * after the *last* resize event in a burst. This prevents the Lustre
 * update loop from being flooded during a continuous window-drag.
 *
 * @param {function(): void} callback Fired after each resize burst settles.
 */
export function on_resize(callback) {
  let pending = null;
  window.addEventListener("resize", () => {
    if (pending !== null) {
      clearTimeout(pending);
    }
    pending = setTimeout(() => {
      pending = null;
      callback();
    }, RESIZE_DEBOUNCE_MS);
  });
}

/**
 * Installs a `keydown` listener for `ArrowRight`. `ArrowLeft` is
 * intentionally omitted — backward page navigation is disabled.
 * `preventDefault()` suppresses the browser's default scroll-by-line
 * behaviour so the arrow key turns the page rather than also scrolling
 * the viewport.
 *
 * @param {function(): void} next_callback Fired on `ArrowRight`.
 */
export function on_arrow_key(next_callback) {
  window.addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight") {
      event.preventDefault();
      next_callback();
    }
  });
}

/**
 * Installs a `keydown` listener for the platform undo chord (`Cmd+Z`
 * on macOS, `Ctrl+Z` elsewhere). `preventDefault()` stops the browser's
 * native undo (e.g. undeleting typed text in a focused input) from
 * running alongside the reader's undo. The `Shift` variant is excluded
 * so a future redo handler can claim `Cmd+Shift+Z` / `Ctrl+Shift+Z`
 * without conflict.
 *
 * @param {function(): void} callback Fired on the undo chord.
 */
export function on_undo_key(callback) {
  window.addEventListener("keydown", (event) => {
    // The undo chord is Cmd+Z on macOS and Ctrl+Z everywhere else.
    // Skip Shift+Z so the redo chord stays available for a future
    // redo handler. `event.key` is the post-modifier resolution, so
    // it reads "z" for an unshifted press and "Z" for shifted — we
    // accept both because some keyboard layouts report uppercase
    // even without shift held.
    const is_undo_key = event.key === "z" || event.key === "Z";
    const has_meta = event.metaKey || event.ctrlKey;
    if (is_undo_key && has_meta && !event.shiftKey) {
      event.preventDefault();
      callback();
    }
  });
}

export function on_vim_keys(
  focus_previous_callback,
  focus_paragraph_down_callback,
  focus_paragraph_up_callback,
  focus_next_callback,
  space_callback,
  undo_callback,
) {
  window.addEventListener("keydown", (event) => {
    // Skip when the reader is typing into an input — the cursor
    // would otherwise eat the keystroke. Form controls aren't on
    // any page today, but this is the lowest-cost guard against a
    // future search box or settings panel.
    const tag = event.target && event.target.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA") return;

    // Modifier chords belong to the existing undo handler and to
    // the browser (Ctrl+L focuses the URL bar, Cmd+H hides the
    // window on macOS, etc.). Bailing here keeps every modifier
    // combination available rather than silently stealing it.
    if (event.metaKey || event.ctrlKey || event.altKey) return;

    switch (event.key) {
      case "h":
        event.preventDefault();
        focus_previous_callback();
        break;
      case "j":
        event.preventDefault();
        focus_paragraph_down_callback();
        break;
      case "k":
        event.preventDefault();
        focus_paragraph_up_callback();
        break;
      case "l":
        event.preventDefault();
        focus_next_callback();
        break;
      case " ":
        // Without preventDefault the browser scrolls one viewport
        // height per Space — the reader's vertical reading flow
        // would jump out from under the cursor.
        event.preventDefault();
        space_callback();
        break;
      case "u":
        event.preventDefault();
        undo_callback();
        break;
    }
  });
}

/**
 * Reads `prefers-color-scheme: dark` off the user agent media list.
 * Used once at boot to seed the reader's theme; subsequent toggles
 * flow through the settings panel and bypass this query.
 *
 * `window.matchMedia` is universal on browser targets — no defensive
 * branch needed.
 *
 * @returns {boolean} True when the OS reports a dark colour scheme.
 */
export function get_prefers_color_scheme_dark() {
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

/**
 * Reads `prefers-reduced-motion: reduce` off the user agent media list.
 * The reader honours the OS preference at boot; when set, the body
 * carries `vi-reduced-motion` and the CSS strips transitions from the
 * `.sentence` rule so erases snap rather than fade.
 *
 * @returns {boolean} True when the OS asks for reduced motion.
 */
export function get_prefers_reduced_motion() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/**
 * Sets a CSS custom property on `:root` (`document.documentElement`).
 * Every rule referencing the property re-resolves on the next paint.
 *
 * @param {string} name CSS custom property name including the leading `--`.
 * @param {string} value The new value, as a CSS-syntax string.
 */
export function set_css_property(name, value) {
  document.documentElement.style.setProperty(name, value);
}

/**
 * Toggles a class on `document.body`. Centralising the body-class
 * machinery lets the Lustre view stay free of theme/setting markup —
 * the view renders identical HTML regardless of which toggles are
 * active, and the CSS reads body classes to flip the relevant rules.
 *
 * @param {string} class_name Class to add or remove.
 * @param {boolean} enabled When `true`, the class is added; otherwise removed.
 */
export function set_body_class(class_name, enabled) {
  if (enabled) {
    document.body.classList.add(class_name);
  } else {
    document.body.classList.remove(class_name);
  }
}

/**
 * Ensures the document's `<meta name="viewport">` carries
 * `viewport-fit=cover`. iOS only exposes non-zero
 * `env(safe-area-inset-*)` values when the viewport meta opts into
 * cover mode; without this, content rendered behind the notch and home
 * indicator clips into system UI. `lustre_dev_tools` injects a stock
 * `width=device-width, initial-scale=1` viewport meta with no cover
 * flag, so we patch the existing tag in place rather than inserting a
 * duplicate (which would let the older one win depending on parser
 * order). When no viewport meta is present we create one.
 */
export function ensure_viewport_fit_cover() {
  const desired = "width=device-width, initial-scale=1, viewport-fit=cover";
  let meta = document.querySelector('meta[name="viewport"]');
  if (meta === null) {
    meta = document.createElement("meta");
    meta.setAttribute("name", "viewport");
    document.head.appendChild(meta);
  }
  if (meta.getAttribute("content") !== desired) {
    meta.setAttribute("content", desired);
  }
}

/**
 * Schedules the fade engine's next word tick. Clears any timer
 * currently in flight so callers don't have to track the handle
 * — the module owns the single-slot state. `callback` is invoked
 * with no arguments after `delay_ms` milliseconds; the slot is
 * cleared synchronously inside the wrapper before the callback
 * runs so a re-entrant `start_word_timer` from inside the
 * callback (the common case — the AdvanceWord reducer schedules
 * the next tick) installs cleanly into a known-empty slot.
 *
 * @param {number} delay_ms Delay in milliseconds.
 * @param {function(): void} callback Fired once after the delay.
 */
export function start_word_timer(delay_ms, callback) {
  if (word_timer_id !== null) {
    clearTimeout(word_timer_id);
  }
  word_timer_id = setTimeout(() => {
    word_timer_id = null;
    callback();
  }, delay_ms);
}

/**
 * Cancels any in-flight word timer. Safe to call when no timer
 * is scheduled — the slot is checked before `clearTimeout`. Used
 * by `PauseFade`, by mode switches leaving RealTime, and by the
 * internal `apply_stop_fade` helper on engine exhaustion.
 */
export function clear_word_timer() {
  if (word_timer_id !== null) {
    clearTimeout(word_timer_id);
    word_timer_id = null;
  }
}
