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
import { NetworkError, HttpError } from "./ffi.mjs";

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

/**
 * Issues a GET request and resolves `on_complete` with either the raw
 * response body or a typed `FetchError`. The Gleam-side decoder runs
 * over the returned string; keeping decoding off the FFI seam means
 * one shape of FFI primitive serves every JSON endpoint regardless of
 * payload structure.
 *
 * The implementation mirrors the `measure_paragraphs` pattern at the
 * top of this file: every result value is constructed from the Gleam
 * runtime classes (`Ok`, `GleamError`, and the `FetchError` variants
 * imported from `./ffi.mjs`) so the value round-trips back into
 * Gleam's type system without further coercion.
 *
 * @param {string} url Absolute or relative URL.
 * @param {function(Ok<string>|GleamError): void} on_complete
 */
export function fetch_json_get(url, on_complete) {
  do_fetch(url, undefined, on_complete);
}

/**
 * POST counterpart to `fetch_json_get`. Sends `body` as the request
 * payload with `Content-Type: application/json` and otherwise behaves
 * identically. The caller is responsible for stringifying the body —
 * we accept a `String` rather than a Gleam `json.Json` so the FFI
 * stays oblivious to the payload's shape.
 *
 * @param {string} url Absolute or relative URL.
 * @param {string} body JSON-encoded request body.
 * @param {function(Ok<string>|GleamError): void} on_complete
 */
export function fetch_json_post(url, body, on_complete) {
  do_fetch(
    url,
    { method: "POST", headers: { "Content-Type": "application/json" }, body },
    on_complete,
  );
}

/**
 * PUT counterpart to `fetch_json_post`. Same shape, different method —
 * settings persistence and per-book override writes use PUT so the
 * server can keep the create/update split clean (`POST /api/books` for
 * creates, `PUT /api/.../settings` for full-record updates).
 *
 * @param {string} url Absolute or relative URL.
 * @param {string} body JSON-encoded request body.
 * @param {function(Ok<string>|GleamError): void} on_complete
 */
export function fetch_json_put(url, body, on_complete) {
  do_fetch(
    url,
    { method: "PUT", headers: { "Content-Type": "application/json" }, body },
    on_complete,
  );
}

/**
 * DELETE counterpart to `fetch_json_get`. Issues a DELETE request with no
 * body; on success the server returns 204 No Content with an empty body,
 * which `on_complete` receives as `Ok("")`.
 *
 * @param {string} url Absolute or relative URL.
 * @param {function(Ok<string>|GleamError): void} on_complete
 */
export function fetch_json_delete(url, on_complete) {
  do_fetch(url, { method: "DELETE" }, on_complete);
}

/**
 * PATCH counterpart to `fetch_json_put`. Used by the metadata-edit
 * endpoint which carries a partial-record payload (one or more of
 * `title` / `author` / `genre`); the server's `PATCH /api/books/:id`
 * handler reads each field's three-way state (absent, null, set) to
 * decide whether to preserve, clear, or overwrite that column.
 *
 * @param {string} url Absolute or relative URL.
 * @param {string} body JSON-encoded request body.
 * @param {function(Ok<string>|GleamError): void} on_complete
 */
export function fetch_json_patch(url, body, on_complete) {
  do_fetch(
    url,
    { method: "PATCH", headers: { "Content-Type": "application/json" }, body },
    on_complete,
  );
}

/**
 * Shared implementation for `fetch_json_get` / `fetch_json_post`. The
 * promise chain has three resolution points and each maps to one
 * `FetchError` variant:
 *
 * 1. `fetch()` rejection → `NetworkError` (TypeError; DNS/CORS/offline).
 * 2. Non-2xx response → `HttpError(status, body)` so the caller has
 *    both the numeric code and any server-supplied error body for
 *    surfacing through a toast or console.
 * 3. Success → `Ok(body_string)`. Decoding stays in Gleam.
 *
 * `response.text()` itself can theoretically reject, but in practice
 * only for aborted requests; we treat any second-phase rejection as
 * a `NetworkError` so the caller sees a single failure surface.
 *
 * @param {string} url
 * @param {RequestInit|undefined} init
 * @param {function(Ok<string>|GleamError): void} on_complete
 */
function do_fetch(url, init, on_complete) {
  window
    .fetch(url, init)
    .then((response) => {
      return response.text().then((body) => {
        if (!response.ok) {
          on_complete(new GleamError(new HttpError(response.status, body)));
          return;
        }
        on_complete(new Ok(body));
      });
    })
    .catch((error) => {
      const message = error && error.message ? String(error.message) : String(error);
      on_complete(new GleamError(new NetworkError(message)));
    });
}

/**
 * Wall-clock now formatted as ISO 8601 UTC with millisecond precision
 * (`YYYY-MM-DDTHH:MM:SS.sssZ`). Matches the server's canonicalised form
 * so a round-trip through `clock.parse_iso8601` is a no-op. Used to
 * stamp `reading_state.updated_at` on every PUT.
 *
 * @returns {string}
 */
export function now_iso8601() {
  return new Date().toISOString();
}

/**
 * Pack a Gleam `List(Int)` of indices into a base64-encoded bitset.
 * Bit N (MSB-first within each byte) is set when N appears in the list;
 * the resulting `Uint8Array` is sized to the smallest power-of-eight
 * that still fits the largest index. An empty list returns an empty
 * string so the caller can short-circuit to JSON `null` rather than
 * round-tripping an empty BitArray.
 *
 * @param {List} indices Gleam-encoded linked list of non-negative integers.
 * @returns {string} Base64 representation of the packed bitset.
 */
export function pack_indices_to_base64(indices) {
  let max = -1;
  for (const index of indices) {
    if (index > max) max = index;
  }
  if (max < 0) {
    return "";
  }
  const bytes = new Uint8Array(Math.floor(max / 8) + 1);
  for (const index of indices) {
    if (index < 0) continue;
    const byte_index = Math.floor(index / 8);
    const bit_index = 7 - (index % 8);
    bytes[byte_index] |= 1 << bit_index;
  }
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

/**
 * Returns a fresh RFC 4122 v4 UUID. Prefers `crypto.randomUUID()` when
 * available (secure contexts: HTTPS or localhost). Falls back to a
 * `crypto.getRandomValues`-based implementation for non-secure contexts
 * (e.g., mobile browsers hitting a LAN dev server over plain HTTP).
 *
 * Used to stamp reading-session ids before the POST hits the server so
 * the follow-up PUT (and the visibilitychange-triggered end PUT) can
 * target the same row without waiting for the response.
 *
 * @returns {string}
 */
export function generate_uuid() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  // Fallback: RFC 4122 v4 UUID from crypto.getRandomValues (available
  // in all modern browsers regardless of secure context).
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  // Set version (4) and variant (10xx) bits per RFC 4122.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return (
    hex.slice(0, 8) + "-" +
    hex.slice(8, 12) + "-" +
    hex.slice(12, 16) + "-" +
    hex.slice(16, 20) + "-" +
    hex.slice(20, 32)
  );
}

/**
 * Installs a `visibilitychange` listener on `document`. The Gleam
 * callback receives `true` when the tab becomes visible and `false`
 * when it becomes hidden. Used by the reading-session lifecycle to
 * end a session on tab hide (the reader is no longer engaged) and to
 * start a new one on tab show.
 *
 * The listener persists for the lifetime of the page.
 *
 * @param {function(boolean): void} callback
 */
export function add_visibility_listener(callback) {
  document.addEventListener("visibilitychange", () => {
    callback(document.visibilityState === "visible");
  });
}

/**
 * Module-level slot for the most recent session-update snapshot. The
 * Gleam reducer stamps this from every arm that mutates session
 * counters (open, page turn, word erase, lock-in, close). On
 * `pagehide` the listener below flushes whatever is currently in the
 * slot via `navigator.sendBeacon` — a reliable best-effort PUT that
 * the browser delivers even after the document unloads, unlike
 * `fetch()` which often gets cancelled on unload paths.
 *
 * Cleared to `null` by `set_session_snapshot("", "")` so a clean close
 * does not double-fire the PUT alongside the `pagehide` event.
 */
let session_snapshot = null;

/**
 * Stamp or clear the session snapshot slot. Both `url` and `body`
 * empty clears the slot — used by `refresh_session_snapshot` when no
 * session is in flight. Either-empty (one populated, the other
 * blank) is treated as a programming error: clearing on either-empty
 * would let a future caller who passed a non-empty url with an empty
 * body silently nuke the snapshot. Require both fields populated
 * before stamping, both empty before clearing.
 *
 * @param {string} url
 * @param {string} body
 */
export function set_session_snapshot(url, body) {
  if (url === "" && body === "") {
    session_snapshot = null;
    return;
  }
  if (url === "" || body === "") {
    // Refuse the half-formed pair rather than guessing. The Gleam
    // caller (`refresh_session_snapshot`) only ever passes both
    // populated or both empty; anything else is a bug at the call
    // site that an undefined-behaviour clear would mask.
    return;
  }
  session_snapshot = { url, body };
}

/**
 * Installs a `pagehide` listener that flushes the in-slot snapshot
 * via `sendBeacon`. The spec routes `sendBeacon` through a dedicated
 * delivery queue the browser can keep alive past unload — the typical
 * failure mode of `fetch()` during unload (cancelled request, lost
 * data) is avoided.
 *
 * The Blob carries the canonical `application/json` content-type so
 * the server's existing `application/json` PUT handler accepts it
 * without a separate body parser branch.
 *
 * The listener clears the slot after delivery so a subsequent
 * `pagehide` (modern browsers can fire it more than once per
 * navigation) does not re-flush stale data.
 */
export function add_pagehide_listener() {
  window.addEventListener("pagehide", () => {
    if (session_snapshot !== null) {
      const blob = new Blob([session_snapshot.body], {
        type: "application/json",
      });
      navigator.sendBeacon(session_snapshot.url, blob);
      session_snapshot = null;
    }
  });
}

/**
 * Wall-clock now as integer milliseconds since the Unix epoch. Used by
 * the reading-session reducer to compute the duration of a session
 * locally; the canonical ISO-8601 stamp goes over the wire via
 * `now_iso8601`, but arithmetic on strings is awkward and rounding
 * the difference to whole seconds here keeps the in-flight counter
 * stable across rapid pause / resume cycles.
 *
 * @returns {number}
 */
export function now_ms() {
  return Date.now();
}

/**
 * Inverse of `pack_indices_to_base64`. Decodes the base64 string to
 * bytes and returns one Gleam-encoded list entry per set bit, in
 * ascending index order. An empty or whitespace-only input returns an
 * empty list. Padding bits beyond the largest set index are preserved
 * — the encoder only writes whole bytes, so a few trailing zero bits
 * are expected and contribute no indices.
 *
 * @param {string} encoded Base64-encoded bitset.
 * @returns {List} Gleam-encoded linked list of non-negative integers.
 */
export function unpack_base64_to_indices(encoded) {
  if (typeof encoded !== "string" || encoded.length === 0) {
    return toList([]);
  }
  let binary;
  try {
    binary = atob(encoded);
  } catch (_error) {
    return toList([]);
  }
  const indices = [];
  for (let byte_index = 0; byte_index < binary.length; byte_index++) {
    const byte = binary.charCodeAt(byte_index);
    if (byte === 0) continue;
    for (let bit = 0; bit < 8; bit++) {
      if (byte & (1 << (7 - bit))) {
        indices.push(byte_index * 8 + bit);
      }
    }
  }
  return toList(indices);
}
