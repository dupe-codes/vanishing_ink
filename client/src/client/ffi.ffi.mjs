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
const RESIZE_DEBOUNCE_MS = 250;

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
 * Installs a `keydown` listener for `ArrowLeft` and `ArrowRight`.
 * `preventDefault()` suppresses the browser's default scroll-by-line
 * behaviour so arrow key presses turn pages rather than also scrolling
 * the viewport.
 *
 * @param {function(): void} previous_callback Fired on `ArrowLeft`.
 * @param {function(): void} next_callback Fired on `ArrowRight`.
 */
export function on_arrow_key(previous_callback, next_callback) {
  window.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      previous_callback();
    } else if (event.key === "ArrowRight") {
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
