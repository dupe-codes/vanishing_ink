// JavaScript implementation of `client/ffi.gleam`. Returns
// runtime-shaped Gleam values so the Gleam-side signatures
// (`Result(Float, Nil)`, `List(#(Int, Float))`) round-trip without
// extra adaptation. `Ok`/`Error` and `toList` are imported from the
// compiled client `gleam.mjs` re-export (which itself re-exports the
// prelude) so the constructed values match the runtime classes the
// rest of the program builds.

import { Ok, Error as GleamError, toList } from "../gleam.mjs";

const PARAGRAPH_INDEX_ATTRIBUTE = "data-paragraph-global-index";
const RESIZE_DEBOUNCE_MS = 250;

export function get_viewport_height() {
  return window.innerHeight;
}

export function get_element_height(selector) {
  const el = document.querySelector(selector);
  if (el === null) {
    return new GleamError(undefined);
  }
  return new Ok(el.getBoundingClientRect().height);
}

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
