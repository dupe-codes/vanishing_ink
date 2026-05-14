# foliate-js (vendored)

Parse-only snapshot of [foliate-js](https://github.com/johnfactotum/foliate-js)
used by the ePub-import feature. Vendored rather than installed via npm
because foliate-js does not publish releases — pinning to a specific
commit is the only durable approach.

## Location

Lives inside `client/src/client/vendor/` rather than at the project's
top-level `client/vendor/`. The Lustre dev server only exposes files
that live under `build/dev/javascript/` to the browser, and the Gleam
compiler only mirrors files into the build tree when they sit inside
`src/`. Placing the vendored modules outside `src/` would mean the
browser cannot load them via relative imports from `epub.ffi.mjs` at
dev time. The trade-off is that the vendor tree shows up in the
source listing — the README and LICENSE alongside the JS files mark
the boundary so the reader knows these are not first-party code.

## Pinned commit

`78914aef4466eb960965702401634c2cb348e9b1` (May 2026 snapshot from `main`).

## Files

- `epub.js` — EPUB parser. Exports the `EPUB` class which accepts a
  loader (`{ loadText, loadBlob, getSize, sha1 }`) and exposes
  `metadata`, `sections[*].createDocument()`, etc. once `init()`
  resolves.
- `epubcfi.js` — CFI parser. Imported by `epub.js`; not used directly
  here.
- `vendor/zip.js` — `@zip.js/zip.js` minified bundle, sourced from
  foliate-js's own `vendor/`. Provides the `ZipReader` / `BlobReader` /
  `TextWriter` / `BlobWriter` primitives `epub.js` needs to read entries
  out of the .epub container.
- `LICENSE` — MIT, John Factotum.

## Not vendored

The viewer/renderer modules (`view.js`, `paginator.js`, `reader.js`,
`overlayer.js`, …) are intentionally omitted — we only parse, never
render through foliate-js.
