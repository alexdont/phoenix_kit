// Pins the transport-cache clearing against Phoenix's real key.
//
// Phoenix stores its sticky longpoll fallback under
// `phx:fallback:<transport>` (sessionStorage, see phoenix.js
// getSession/storeSession). The old filter excluded every "phx:"-prefixed
// key as "PhoenixKit's own", so it never cleared the flag it was written
// for — and a browser that fell back once stayed on longpoll for the tab's
// life: laggy, and prone to full-page reloads that ate in-progress work.
//
//   node --test test/js/transport_cache.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

test("the filter clears Phoenix's fallback key and spares PhoenixKit's", () => {
  const start = src.indexOf("function isTransportKey(k)");
  assert.notStrictEqual(start, -1, "could not find the transport key filter");
  const ret = src.indexOf("return", start);
  const end = src.indexOf(";", src.indexOf("!k.startsWith('phx:')", ret)) + 1;
  const isTransportKey = new Function("k", src.slice(ret, end));

  assert.strictEqual(isTransportKey("phx:fallback:longpoll"), true,
    "the key Phoenix actually writes (phoenix.js storeSession) is cleared — " +
    "this is the whole point of the routine");
  assert.strictEqual(isTransportKey("phx:theme"), false,
    "PhoenixKit's own phx:* keys survive");
  assert.strictEqual(isTransportKey("phx:longpoll-legacy"), false,
    "unknown phx:* keys are left alone too");
  assert.strictEqual(isTransportKey("some_phx_transport"), true,
    "the old catch-all for unprefixed phx keys still applies");
  assert.strictEqual(isTransportKey("unrelated"), false);
});

test("phoenix.js really does use that key shape", () => {
  const phoenix = fs.readFileSync(
    path.join(__dirname, "..", "..", "deps", "phoenix", "priv", "static", "phoenix.js"),
    "utf8"
  );
  assert.ok(phoenix.includes("phx:fallback:"),
    "if Phoenix renames its fallback key, the filter above must follow");
});
