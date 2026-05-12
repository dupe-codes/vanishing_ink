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

  const nodes = container.querySelectorAll(`[${PARAGRAPH_INDEX_ATTRIBUTE}]`);
  const pairs = [];
  for (const node of nodes) {
    const raw = node.getAttribute(PARAGRAPH_INDEX_ATTRIBUTE);
    const index = Number.parseInt(raw, 10);
    if (!Number.isFinite(index)) continue;
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
      previous_callback();
    } else if (event.key === "ArrowRight") {
      next_callback();
    }
  });
}
