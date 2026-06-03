/* ============================================================================
   Pensieve — recall math (client-side, like the real shim)
   A small but honest stand-in for the on-device pipeline:
   - tokenize + tf-idf + cosine ranking so "live recall" actually ranks by
     meaning, the way bge + findNearest COSINE does in the product;
   - a real SHA-256 so the audit chain genuinely hashes (and genuinely breaks
     when truncated);
   - a 2D cloak demo using a true orthonormal transform, so the "distances are
     preserved, basis is hidden, cross-tenant cosine survives" claims are not
     hand-waved — they're computed in front of you.
   ========================================================================== */
(function () {
  "use strict";

  const STOP = new Set(
    ("a an the of to in on at for and or but is are was were be been being this that these those " +
      "it its with as by from your you i we they he she them our their not no can cannot do does did " +
      "so if then than into over under out up down about across only just more most less also per via " +
      "have has had will would should could may might must each every any all some both one two").split(" ")
  );

  function tokenize(text) {
    return (text || "")
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, " ")
      .split(/\s+/)
      .map((w) => w.replace(/^-+|-+$/g, ""))
      .filter((w) => w.length > 1 && !STOP.has(w));
  }

  // Build an idf table once over the memory corpus.
  let IDF = null;
  function buildIdf(memories) {
    const df = Object.create(null);
    const N = memories.length;
    for (const m of memories) {
      const seen = new Set(tokenize(m.title + " " + m.body));
      for (const t of seen) df[t] = (df[t] || 0) + 1;
    }
    IDF = Object.create(null);
    for (const t in df) IDF[t] = Math.log((N + 1) / (df[t] + 0.5)) + 1;
    return IDF;
  }
  function idf(t) {
    if (!IDF) buildIdf(window.PENSIEVE.MEMORIES);
    return IDF[t] || Math.log(window.PENSIEVE.MEMORIES.length + 1) + 1;
  }

  function vectorize(tokens) {
    const tf = Object.create(null);
    for (const t of tokens) tf[t] = (tf[t] || 0) + 1;
    const v = Object.create(null);
    let norm = 0;
    for (const t in tf) {
      const w = (1 + Math.log(tf[t])) * idf(t);
      v[t] = w;
      norm += w * w;
    }
    norm = Math.sqrt(norm) || 1;
    for (const t in v) v[t] /= norm;
    return v;
  }

  // Memo memory vectors (cache on the object).
  function memVector(m) {
    if (!m.__vec) m.__vec = vectorize(tokenize(m.title + " " + m.title + " " + m.body));
    return m.__vec;
  }

  function cosineMap(a, b) {
    let dot = 0;
    const small = Object.keys(a).length <= Object.keys(b).length ? a : b;
    const big = small === a ? b : a;
    for (const t in small) if (big[t]) dot += small[t] * big[t];
    return dot; // both unit-normalized
  }

  /**
   * Rank memories against a free-text query. Returns sorted descending with a
   * relevance score in [0,1] and the matched terms for highlighting. A faint
   * recency prior nudges ties, mirroring "last recalled" weighting.
   */
  function rank(query, memories, limit) {
    const qTokens = tokenize(query);
    if (!qTokens.length) return [];
    const qVec = vectorize(qTokens);
    const qSet = new Set(qTokens);
    const now = Date.parse("2026-06-02T19:10:00Z");
    const results = memories
      .map((m) => {
        let score = cosineMap(qVec, memVector(m));
        // gentle recency prior (max +0.04)
        const age = (now - Date.parse(m.lastRecalledAt)) / 8.64e7; // days
        score += Math.max(0, 0.04 - age * 0.004);
        const matched = tokenize(m.title + " " + m.body).filter((t) => qSet.has(t));
        return { mem: m, score: Math.min(1, score), matched: Array.from(new Set(matched)) };
      })
      .filter((r) => r.score > 0.02)
      .sort((a, b) => b.score - a.score);
    return typeof limit === "number" ? results.slice(0, limit) : results;
  }

  // Highlight matched query terms inside a snippet (escaped).
  function highlight(text, terms) {
    const esc = text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
    if (!terms || !terms.length) return esc;
    const uniq = Array.from(new Set(terms.filter(Boolean))).sort((a, b) => b.length - a.length);
    const re = new RegExp("\\b(" + uniq.map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|") + ")(s|ed|ing)?\\b", "gi");
    return esc.replace(re, "<mark>$&</mark>");
  }

  // A short snippet centered on the first matched term.
  function snippetAround(text, terms, len) {
    len = len || 180;
    if (!terms || !terms.length) return text.slice(0, len) + (text.length > len ? "…" : "");
    const lower = text.toLowerCase();
    let idx = -1;
    for (const t of terms) {
      const i = lower.indexOf(t.toLowerCase());
      if (i >= 0 && (idx < 0 || i < idx)) idx = i;
    }
    if (idx < 0) return text.slice(0, len) + (text.length > len ? "…" : "");
    let start = Math.max(0, idx - 50);
    const end = Math.min(text.length, start + len);
    let s = (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
    return s;
  }

  /* ---- SHA-256 (compact, synchronous) ----------------------------------- */
  // Public-domain style minimal implementation; used so the audit chain is a
  // real hash chain, not a decorative one.
  function sha256(ascii) {
    function rrot(x, n) { return (x >>> n) | (x << (32 - n)); }
    const K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];

    // utf-8 encode
    const bytes = [];
    for (let i = 0; i < ascii.length; i++) {
      let c = ascii.charCodeAt(i);
      if (c < 128) bytes.push(c);
      else if (c < 2048) { bytes.push(192 | (c >> 6), 128 | (c & 63)); }
      else { bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63)); }
    }
    const l = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    for (let i = 7; i >= 0; i--) bytes.push((l / Math.pow(2, i * 8)) & 0xff);

    const w = new Array(64);
    for (let j = 0; j < bytes.length; j += 64) {
      for (let i = 0; i < 16; i++)
        w[i] = (bytes[j + i * 4] << 24) | (bytes[j + i * 4 + 1] << 16) | (bytes[j + i * 4 + 2] << 8) | bytes[j + i * 4 + 3];
      for (let i = 16; i < 64; i++) {
        const s0 = rrot(w[i - 15], 7) ^ rrot(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = rrot(w[i - 2], 17) ^ rrot(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let [a, b, c, d, e, f, g, hh] = h;
      for (let i = 0; i < 64; i++) {
        const S1 = rrot(e, 6) ^ rrot(e, 11) ^ rrot(e, 25);
        const ch = (e & f) ^ (~e & g);
        const t1 = (hh + S1 + ch + K[i] + w[i]) | 0;
        const S0 = rrot(a, 2) ^ rrot(a, 13) ^ rrot(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = (S0 + maj) | 0;
        hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h = [(h[0] + a) | 0, (h[1] + b) | 0, (h[2] + c) | 0, (h[3] + d) | 0, (h[4] + e) | 0, (h[5] + f) | 0, (h[6] + g) | 0, (h[7] + hh) | 0];
    }
    return h.map((x) => (x >>> 0).toString(16).padStart(8, "0")).join("");
  }

  // Assign prevHash + hash across an ordered list of audit events.
  function buildChain(events) {
    let prev = "0".repeat(64);
    return events.map((ev) => {
      const payload = JSON.stringify({ a: ev.actor, x: ev.action, d: ev.domain, t: ev.time, n: ev.detail });
      const hash = sha256(prev + payload);
      const node = Object.assign({}, ev, { prevHash: prev, hash, payload });
      prev = hash;
      return node;
    });
  }

  // Verify a (possibly tampered) chain. Returns the first index where the
  // recomputed hash diverges, or -1 if intact.
  function verifyChain(nodes) {
    let prev = "0".repeat(64);
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      const recomputed = sha256(prev + n.payload);
      if (n.prevHash !== prev || n.hash !== recomputed) return i;
      prev = n.hash;
    }
    return -1;
  }

  /* ---- 2D cloak demo (honest geometry) ---------------------------------- */
  // Seeded RNG so the picture is stable across renders (no Math.random).
  function rng(seed) {
    let s = seed >>> 0;
    return function () {
      s = (s * 1664525 + 1013904223) >>> 0;
      return s / 4294967296;
    };
  }
  // A real 2D rotation by angle θ (orthonormal ⇒ distance & inner-product preserving).
  function rot(theta) {
    const c = Math.cos(theta), s = Math.sin(theta);
    return ([x, y]) => [c * x - s * y, s * x + c * y];
  }
  function dist(a, b) { return Math.hypot(a[0] - b[0], a[1] - b[1]); }
  function cos2(a, b) {
    const d = a[0] * b[0] + a[1] * b[1];
    const na = Math.hypot(a[0], a[1]) || 1, nb = Math.hypot(b[0], b[1]) || 1;
    return d / (na * nb);
  }

  // Produce a small cloud + its cloak under member A and member B, with the
  // measured invariants. The "raw" cloud is what you'd never upload; the cloaked
  // clouds are what the server holds.
  function cloakDemo(n) {
    n = n || 9;
    const r = rng(1337);
    const raw = [];
    for (let i = 0; i < n; i++) {
      // cluster-ish layout so geometry is visible
      const cluster = i % 3;
      const cx = [-0.45, 0.4, 0.05][cluster];
      const cy = [0.3, 0.35, -0.5][cluster];
      raw.push([cx + (r() - 0.5) * 0.4, cy + (r() - 0.5) * 0.4]);
    }
    const Qa = rot(2.3), Qb = rot(2.3 + 0.62); // two different keys (rotations)
    const cloakA = raw.map(Qa), cloakB = raw.map(Qb);

    // invariant 1: pairwise distance preserved under Qa (max abs error)
    let distErr = 0;
    for (let i = 0; i < n; i++)
      for (let j = i + 1; j < n; j++)
        distErr = Math.max(distErr, Math.abs(dist(raw[i], raw[j]) - dist(cloakA[i], cloakA[j])));

    // invariant 2: cross-tenant cosine of the SAME item under A vs B (mean |cos|)
    let crossCos = 0;
    for (let i = 0; i < n; i++) crossCos += Math.abs(cos2(cloakA[i], cloakB[i]));
    crossCos /= n;

    return { raw, cloakA, cloakB, distErr, crossCos };
  }

  window.RECALL = {
    tokenize, buildIdf, rank, highlight, snippetAround,
    sha256, buildChain, verifyChain, cloakDemo,
  };
})();
