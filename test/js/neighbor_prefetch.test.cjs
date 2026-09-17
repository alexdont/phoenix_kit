// Pins the viewer's neighbour warming.
//
// An arrow press remounts the viewer on the next file, and that file's
// small + large variants used to start downloading only then — the
// download WAS the wait between pressing → and seeing the picture. The
// modal now carries the neighbours' variant URLs, and ViewerKeydown
// warms them on mount, deduped page-wide across remounts.
//
//   node --test test/js/neighbor_prefetch.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

function loadKeydown() {
  const start = src.indexOf("  window.PhoenixKitHooks.ViewerKeydown = {");
  assert.notStrictEqual(start, -1, "could not find ViewerKeydown");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  const fetched = [];
  function FakeImage() {}
  Object.defineProperty(FakeImage.prototype, "src", {
    set(v) { fetched.push(v); }, get() { return null; },
  });
  const dispatched = [];
  const win = {
    addEventListener: () => {}, removeEventListener: () => {},
    dispatchEvent: (e) => dispatched.push(e),
  };
  const doc = { addEventListener: () => {}, removeEventListener: () => {} };
  const fn = new Function("window", "document", "Image", "CustomEvent",
    "window.PhoenixKitHooks = window.PhoenixKitHooks || {};" +
    src.slice(start, end) + "; return window.PhoenixKitHooks.ViewerKeydown;");
  const hook = fn(win, doc, FakeImage, function C(n, o) { this.name = n; this.detail = o && o.detail; });
  return { hook, fetched, win, dispatched };
}

function mountEl(dataset, colW) {
  return {
    dataset,
    querySelector: (sel) => sel.includes("pk-annotation-actions")
      ? { clientWidth: colW }
      : null,
  };
}

test("mounting the viewer warms both neighbours' variants", () => {
  const { hook, fetched } = loadKeydown();
  hook.mounted.call({ el: mountEl({
    neighborPrefetch: "/f/p/small/aa /f/p/large/ab /f/n/small/ba /f/n/large/bb",
  }, 1200), pushEventTo: () => {} });
  assert.deepStrictEqual(fetched,
    ["/f/p/small/aa", "/f/p/large/ab", "/f/n/small/ba", "/f/n/large/bb"],
    "prev and next, small and large — everything an arrow press will ask for");
});

test("a wide viewer column warms the originals too — a narrow one never", () => {
  // Tessera picks its raster by displayed width against each rung's
  // pixels x 1.1 headroom: past 1920x1.1 CSS px the FIRST pick is the
  // original, and a multi-MB original nothing warmed was the "waiting
  // and waiting" a step onto a big image showed on large monitors.
  const wide = loadKeydown();
  wide.hook.mounted.call({ el: mountEl({
    neighborPrefetch: "/f/n/small/aa",
    neighborPrefetchHi: "/f/n/original/zz",
  }, 2400), pushEventTo: () => {} });
  assert.deepStrictEqual(wide.fetched, ["/f/n/small/aa", "/f/n/original/zz"],
    "past the large rung's reach, the original is what the step will show");

  const narrow = loadKeydown();
  narrow.hook.mounted.call({ el: mountEl({
    neighborPrefetch: "/f/n/small/aa",
    neighborPrefetchHi: "/f/n/original/zz",
  }, 1400), pushEventTo: () => {} });
  assert.deepStrictEqual(narrow.fetched, ["/f/n/small/aa"],
    "where large suffices, multi-MB originals are pure waste — never warmed");
});

test("each URL warms once per page, across remounts", () => {
  const { hook, fetched, win } = loadKeydown();
  const el = mountEl({ neighborPrefetch: "/f/x/small/aa" }, 1200);
  hook.mounted.call({ el, pushEventTo: () => {} });
  // the next file's mount lists the same URL as ITS neighbour
  hook.mounted.call({ el, pushEventTo: () => {} });
  assert.deepStrictEqual(fetched, ["/f/x/small/aa"],
    "the shared page-wide map survives the remount an arrow causes");
});

test("no neighbours, no fetches, no crash", () => {
  const { hook, fetched } = loadKeydown();
  assert.doesNotThrow(() => hook.mounted.call({
    el: { dataset: {}, querySelector: () => null }, pushEventTo: () => {} }));
  assert.deepStrictEqual(fetched, []);
});

test("the modal advertises its neighbours", () => {
  const heex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_browser.html.heex"), "utf8");
  assert.ok(heex.includes("data-neighbor-prefetch={neighbor_prefetch}"),
    "ViewerKeydown reads the URLs off its own element");
  assert.ok(/Enum\.at\(siblings, viewer_idx - 1\)/.test(heex) &&
            /Enum\.at\(siblings, viewer_idx \+ 1\)/.test(heex),
    "…built from the same siblings list the arrows step through");
  assert.ok(heex.includes(`&1.file_type == "image"`),
    "videos and pdfs are not image-warmable and are skipped");
  assert.ok(heex.includes("data-neighbor-prefetch-hi={neighbor_prefetch_hi}"),
    "the originals ride a separate attribute, warmed only on wide viewports");
  for (const a of ["data-step-prev-src=", "data-step-next-src=",
                   "data-step-prev-rot=", "data-step-next-rot="]) {
    assert.ok(heex.includes(a),
      `the modal advertises ${a} for the step stand-in`);
  }
  assert.ok(/> 4096 and\s*\n\s*is_binary\(n\.urls\["dzi"\]\)/.test(heex),
    "an over-4K file WITH tiles never raster-loads its original — excluded");
});

test("a step re-announces the viewer and re-warms — the modal is patched, not remounted", () => {
  // A step keeps this hook's element (stable id) and only swaps the canvas
  // child, so mounted() fires once per OPEN. Before updated() existed, a
  // step's stand-in waited on a pk:viewer-open that never came (the 8s
  // fallback WAS the "blurry for much much longer"), and every neighbour
  // after the first step went unwarmed.
  const { hook, fetched, dispatched } = loadKeydown();
  const ctx = {
    el: mountEl({ neighborPrefetch: "/f/p/small/aa /f/p/large/ab" }, 1200),
    pushEventTo: () => {},
  };
  hook.mounted.call(ctx);
  fetched.length = 0;
  dispatched.length = 0;

  // The patch rewrote the dataset with the NEW neighbours.
  ctx.el.dataset.neighborPrefetch = "/f/q/small/qq /f/q/large/ql";
  hook.updated.call(ctx);

  const open = dispatched.find((e) => e.name === "pk:viewer-open");
  assert.ok(open, "the stand-in's hand-off rides pk:viewer-open — a step must re-fire it");
  assert.strictEqual(open.detail.el, ctx.el,
    "…with the modal element, so the hold can find the new image");
  assert.deepStrictEqual(fetched, ["/f/q/small/qq", "/f/q/large/ql"],
    "and the NEXT press's neighbours warm now, not never");
});

test("a hiDPI column counts device pixels for the original warm", () => {
  // Tessera 0.3.7 picks its raster against physical pixels, so a 4K
  // monitor at 200% OS scaling (~1632 CSS px, dpr 2) opens straight on
  // the original — the warm gate must count the same pixels, or exactly
  // those viewers step onto multi-MB originals nothing warmed.
  const { hook, fetched, win } = loadKeydown();
  win.devicePixelRatio = 2;
  hook.mounted.call({
    el: mountEl({
      neighborPrefetch: "/f/n/small/aa",
      neighborPrefetchHi: "/f/n/original/xx",
    }, 1600),
    pushEventTo: () => {},
  });
  assert.ok(fetched.includes("/f/n/original/xx"),
    "1600 CSS px at dpr 2 is 3200 device px — past large's 1920 rung");

  // …and dpr 1 at the same CSS width still skips it, as ever.
  const second = loadKeydown();
  second.hook.mounted.call({
    el: mountEl({
      neighborPrefetch: "/f/n/small/aa",
      neighborPrefetchHi: "/f/n/original/xx",
    }, 1600),
    pushEventTo: () => {},
  });
  assert.ok(!second.fetched.includes("/f/n/original/xx"),
    "a genuinely 1600-device-px column has no use for the original");
});
