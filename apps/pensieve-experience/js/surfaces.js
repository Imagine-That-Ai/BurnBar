/* ============================================================================
   Pensieve — surfaces
   One coherent application, many rooms. Each surface returns { title, render,
   mount }. render() -> HTML; mount(root, ctx) wires behavior and may return a
   cleanup fn the router calls on navigation.
   ========================================================================== */
(function () {
  "use strict";
  const P = window.PENSIEVE;
  const R = window.RECALL;
  const icon = P.icon;
  const E = window.C.esc;

  const qs = (r, s) => r.querySelector(s);
  const qsa = (r, s) => Array.from(r.querySelectorAll(s));

  // deterministic cipher-looking hex from a seed (uses real sha256)
  function cipherBlock(seed, lines) {
    let out = "", h = R.sha256(seed);
    for (let i = 0; i < (lines || 6); i++) {
      h = R.sha256(h + i);
      out += h + (R.sha256(seed + ":" + i).slice(0, 32)) + "\n";
    }
    return out.trim();
  }

  /* ======================================================================
     THE BASIN (home)
     ====================================================================== */
  const basin = {
    title: "The Basin",
    render() {
      const feed = P.RECALL_FEED.map((f) =>
        '<div class="recall-feed-item">' +
          '<span class="live-pulse__beacon" style="--x:0"></span>' +
          '<span class="recall-feed-item__agent">' + E(f.agent) + "</span>" +
          '<span class="recall-feed-item__what">recalled “' + E(f.what) + '”</span>' +
          '<span class="recall-feed-item__when">' + E(f.when) + "</span>" +
        "</div>"
      ).join("");

      const lensMems = ["m-completionbar", "m-engine", "m-cloak-geometry", "m-xcodegen", "m-mem0"].map(P.memById);

      return (
        '<div class="surface__inner stack-8">' +
          '<section class="basin-hero">' +
            '<div class="basin-hero__pool" aria-hidden="true"></div>' +
            '<span class="basin-hero__label arcane">A basin that remembers — and never reads.</span>' +
            '<h1 class="basin-hero__title">Your agents recall the right thing, at the right moment.</h1>' +
            '<p class="basin-hero__sub">Pensieve quietly keeps what matters from your repos, notes, and conversations. ' +
              'Everything is sealed on your devices before it leaves them — the cloud searches memory it can’t read.</p>' +
            '<div class="basin-hero__cta">' +
              '<button class="btn btn--primary" data-go="recall">' + icon("recall") + "Recall a memory</button>" +
              '<button class="btn btn--ghost" data-go="remember">' + icon("quill") + "Remember something</button>" +
              '<button class="btn btn--ghost" data-go="cloak">' + icon("cloak") + "See what the server sees</button>" +
            "</div>" +
          "</section>" +

          '<section class="depth-stats">' +
            depthStat("1,284", "memories held", "chunks", "var(--color-tier-end-to-end)", "rgba(60,214,192,0.28)") +
            depthStat("4", "sources connected", "repos · notes · chat", "var(--color-mercury-bright)", "rgba(199,207,221,0.22)") +
            depthStat("118", "recalls today", "+22 vs yesterday", "var(--color-brass-bright)", "rgba(253,196,44,0.22)") +
            depthStat("3", "agents recalling", "Hermes · Claude · Codex", "var(--color-tier-end-to-end)", "rgba(60,214,192,0.22)") +
          "</section>" +

          '<section class="grid recall-layout">' +
            '<div class="panel stack-4">' +
              '<div class="live-pulse">' +
                '<span class="live-pulse__beacon"></span>' +
                '<span class="small bright">Live recall</span>' +
                '<span class="small muted">what your agents are remembering right now</span>' +
              "</div>" +
              '<div id="recall-feed" class="stack">' + feed + "</div>" +
            "</div>" +
            '<div class="panel stack-4">' +
              '<div class="section-head"><div class="section-head__title">What your agents remember about you</div></div>' +
              window.C.recallLens(lensMems, { label: "Most-recalled strands across your agents" }) +
              '<p class="small muted">Recall is legible by design. Every answer your agents give can name the exact ' +
              'sealed memories it surfaced — never an opaque black box.</p>' +
            "</div>" +
          "</section>" +
        "</div>"
      );
    },
    mount(root) {
      const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      if (reduce) return;
      const feed = qs(root, "#recall-feed");
      const pool = [
        ["Claude (MCP)", "deletes leave a 30-day tombstone"],
        ["Hermes", "recovery is escrow-based, not a password reset"],
        ["Codex", "query mem0 before reading the wiki"],
        ["Claude (MCP)", "only sourceKind and byteCount are plaintext"],
        ["Hermes", "media moves over iroh, not the cloud"],
      ];
      let i = 0;
      const timer = setInterval(() => {
        const [agent, what] = pool[i % pool.length]; i++;
        const node = document.createElement("div");
        node.className = "recall-feed-item rise";
        node.innerHTML =
          '<span class="live-pulse__beacon"></span>' +
          '<span class="recall-feed-item__agent">' + E(agent) + "</span>" +
          '<span class="recall-feed-item__what">recalled “' + E(what) + '”</span>' +
          '<span class="recall-feed-item__when">just now</span>';
        feed.insertBefore(node, feed.firstChild);
        while (feed.children.length > 6) feed.removeChild(feed.lastChild);
        const rect = root.getBoundingClientRect();
        if (window.Basin) window.Basin.ripple(rect.left + 120, window.innerHeight * 0.5);
      }, 7000);
      return () => clearInterval(timer);
    },
  };

  function depthStat(value, label, sub, color, glow) {
    return (
      '<div class="depth-stat">' +
        '<div class="depth-stat__glow" style="--glow-c:' + glow + '"></div>' +
        '<div class="stat__value" style="color:' + color + '">' + value + "</div>" +
        '<div class="stat__label">' + E(label) + "</div>" +
        '<div class="dim tiny" style="margin-top:4px">' + E(sub) + "</div>" +
      "</div>"
    );
  }

  /* ======================================================================
     RECALL
     ====================================================================== */
  const DEFAULT_QUERY = "how does the cloak keep my memories private";
  const recall = {
    title: "Recall",
    render() {
      return (
        '<div class="surface__inner stack-8">' +
          window.C.surfaceHero("Recall · searchKnowledge", "Ask your memory anything.",
            "Type and the surface parts. Strands rise ranked by meaning — matched on-device, decrypted client-side, " +
            "assembled into an answer. The server ranked cloaked vectors it could never read.") +
          '<div class="recall-field">' +
            '<span class="recall-field__glyph">' + icon("recall") + "</span>" +
            '<input id="recall-input" type="text" autocomplete="off" spellcheck="false" ' +
              'placeholder="how do deletes work? what is the launch domain?" value="' + E(DEFAULT_QUERY) + '" ' +
              'aria-label="Recall query" />' +
            '<span class="recall-field__ripple" id="recall-ripple" aria-hidden="true"></span>' +
          "</div>" +
          '<div class="recall-meta" id="recall-meta"></div>' +
          '<div class="grid recall-layout">' +
            '<div id="recall-results" class="recall-results"></div>' +
            '<div class="stack-6">' +
              '<div class="panel stack-4">' +
                window.C.sectionHead("The recall pipeline", "what happens the instant you ask") +
                window.C.pipeline([
                  { icon: "recall", title: "Query embedded + cloaked", desc: "Your question is embedded on-device and cloaked with your vault key.", where: "on your device · <b>bge-small-en-v1.5</b>", done: true },
                  { icon: "engine", title: "Cloud ranks cloaked vectors", desc: "Firestore findNearest COSINE ranks sealed strands it cannot read.", where: "server · <b>findNearest</b>", done: true },
                  { icon: "unlock", title: "Decrypted client-side", desc: "Matching ciphertext returns; only your device unseals it.", where: "on your device", done: true },
                  { icon: "sparkle", title: "Assembled into the answer", desc: "Ranked strands become the context your agent reasons over.", where: "on your device", done: true },
                ]) +
              "</div>" +
              '<div class="panel" id="recall-lens-wrap"></div>' +
            "</div>" +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      const input = qs(root, "#recall-input");
      const results = qs(root, "#recall-results");
      const meta = qs(root, "#recall-meta");
      const lensWrap = qs(root, "#recall-lens-wrap");
      const ripple = qs(root, "#recall-ripple");

      function run(animate) {
        const q = input.value.trim();
        const ranked = R.rank(q, P.MEMORIES, 8);
        if (!q) {
          results.innerHTML = window.C.emptyState("The pool is still", "Ask a question and watch the strands rise.");
          meta.textContent = "";
          lensWrap.innerHTML = "";
          return;
        }
        if (!ranked.length) {
          results.innerHTML = window.C.emptyState("Nothing surfaced", "No sealed strand matched that. Try different words, or remember it first.", "");
          meta.innerHTML = "";
          lensWrap.innerHTML = "";
          return;
        }
        results.innerHTML = ranked
          .map((r, i) => window.C.strand(r.mem, { score: r.score, matched: r.matched, rise: animate, delay: animate ? i * 70 : 0 }))
          .join("");
        meta.innerHTML =
          icon("sparkle") + "<span>" + ranked.length + " strands surfaced</span>" +
          '<span class="dim">·</span><span class="muted">client-side cosine over ' + P.MEMORIES.length + " sealed strands</span>" +
          '<span class="dim">·</span><span class="teal">' + icon("cloak") + " server ranked vectors it can’t read</span>";
        lensWrap.innerHTML =
          window.C.sectionHead("Agent recall lens", "what your agent would cite") +
          window.C.recallLens(ranked.slice(0, 4).map((r) => Object.assign(r.mem, { score: r.score })), { label: "Pulled for this answer" });
      }

      let tmr;
      input.addEventListener("input", () => {
        clearTimeout(tmr);
        const rect = input.getBoundingClientRect();
        if (window.Basin) window.Basin.ripple(rect.left + 60, rect.top + rect.height / 2);
        ripple.classList.remove("go"); void ripple.offsetWidth; ripple.classList.add("go");
        tmr = setTimeout(() => run(true), 120);
      });
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          const first = qs(results, "[data-mem]");
          if (first) first.click();
        }
      });
      run(true);
      setTimeout(() => input.focus({ preventScroll: true }), 60);
    },
  };

  /* ======================================================================
     LIBRARY
     ====================================================================== */
  const library = {
    title: "Library",
    render() {
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Library · browse", "Every memory you’ve sealed.",
            "Grouped by where it came from. Filter and sort freely — the snippets you read here are decrypted on your " +
            "device; the server only ever held ciphertext and two plaintext facets.") +
          '<div class="toolbar">' +
            '<div class="seg" role="tablist" data-filter>' +
              segBtn("all", "All", true) + segBtn("repo_docs", "Repo docs") + segBtn("notes", "Notes") + segBtn("chat_memory", "Chat-derived") +
            "</div>" +
            '<div class="seg" data-sort>' +
              segBtn("recent", "Recent", true) + segBtn("recalled", "Most recalled") + segBtn("largest", "Largest") +
            "</div>" +
            '<label class="search-mini">' + icon("recall", "search-mini__glyph") +
              '<input id="lib-search" type="text" placeholder="filter within your memory…" aria-label="Filter library" /></label>' +
          "</div>" +
          '<div id="library-list" class="stack"></div>' +
        "</div>"
      );
    },
    mount(root) {
      const list = qs(root, "#library-list");
      const search = qs(root, "#lib-search");
      let filter = "all", sort = "recent";

      function draw() {
        let mems = P.MEMORIES.slice();
        const term = search.value.trim().toLowerCase();
        if (filter !== "all") mems = mems.filter((m) => m.sourceKind === filter);
        if (term) mems = mems.filter((m) => (m.title + " " + m.body).toLowerCase().includes(term));
        if (sort === "recent") mems.sort((a, b) => Date.parse(b.committedAt) - Date.parse(a.committedAt));
        if (sort === "recalled") mems.sort((a, b) => b.recallCount - a.recallCount);
        if (sort === "largest") mems.sort((a, b) => b.byteCount - a.byteCount);

        if (!mems.length) { list.innerHTML = window.C.emptyState("No matching strands", "Nothing here matches that filter yet."); return; }

        const groups = { repo_docs: [], notes: [], chat_memory: [] };
        mems.forEach((m) => groups[m.sourceKind].push(m));
        list.innerHTML = Object.keys(groups)
          .filter((k) => groups[k].length)
          .map((k) =>
            '<div class="library-group">' +
              '<div class="library-group__head">' +
                '<span class="library-group__title">' + icon(window.C.KIND_ICON[k]) + E(P.KIND_LABEL[k]) + "</span>" +
                '<span class="library-group__count">' + groups[k].length + "</span>" +
                '<span class="library-group__line"></span>' +
              "</div>" +
              '<div class="stack-3">' + groups[k].map((m) => window.C.strand(m)).join("") + "</div>" +
            "</div>"
          ).join("");
      }
      qsa(root, "[data-filter] button").forEach((b) =>
        b.addEventListener("click", () => { setSeg(root, "[data-filter]", b); filter = b.dataset.seg; draw(); })
      );
      qsa(root, "[data-sort] button").forEach((b) =>
        b.addEventListener("click", () => { setSeg(root, "[data-sort]", b); sort = b.dataset.seg; draw(); })
      );
      search.addEventListener("input", draw);
      draw();
    },
  };

  function segBtn(id, label, on) {
    return '<button class="' + (on ? "is-on" : "") + '" data-seg="' + id + '" role="tab" aria-selected="' + !!on + '">' + E(label) + "</button>";
  }
  function setSeg(root, sel, btn) {
    qsa(root, sel + " button").forEach((b) => { b.classList.toggle("is-on", b === btn); b.setAttribute("aria-selected", b === btn); });
  }

  /* ======================================================================
     MEMORY DETAIL
     ====================================================================== */
  const memory = {
    title: "Memory",
    render(ctx) {
      const m = P.memById(ctx.param) || P.MEMORIES[0];
      const src = P.SOURCES[m.source];
      const facets =
        window.C.facet("embedModel", "bge-small-en-v1.5") +
        window.C.facet("embedDim", "384") +
        window.C.facet("cloakVersion", "1 · 24-reflection Q") +
        window.C.facet("dedupHash", "vault-keyed HMAC (v1)") +
        window.C.facet("seal", "AES-256-GCM") +
        window.C.facet("byteCount", m.byteCount + " B (plaintext facet)");

      const agents = m.agents.map((a) =>
        '<div class="row row--between" style="padding:6px 0;border-top:1px solid var(--color-glass-line)">' +
          '<span class="small">' + icon("brain") + " " + E(a) + "</span>" +
          '<span class="dim tiny mono">recalled ' + window.C.timeAgo(m.lastRecalledAt) + "</span></div>"
      ).join("");

      return (
        '<div class="surface__inner stack-6">' +
          '<button class="btn btn--ghost btn--sm" data-go="library">' + icon("chevron") + "Back to library</button>" +
          '<header class="stack-3">' +
            '<div class="row">' + window.C.tierBadge("end_to_end") +
              window.C.chip(P.KIND_LABEL[m.sourceKind], { icon: window.C.KIND_ICON[m.sourceKind] }) +
              window.C.chip(src.label, { icon: "file" }) + "</div>" +
            '<h1 class="surface-hero__title" style="font-size:clamp(26px,3.5vw,40px)">' + E(m.title) + "</h1>" +
          "</header>" +
          '<div class="memory-detail">' +
            '<div class="stack-6">' +
              '<div class="panel stack-4">' +
                '<div class="row"><span class="eyebrow">Decrypted on this device</span>' +
                  '<span class="spacer"></span><span class="chip chip--seal">' + icon("unlock") + "unsealed locally</span></div>" +
                '<div class="memory-body">' + E(m.body) + "</div>" +
              "</div>" +
              '<div class="panel stack-4">' +
                window.C.sectionHead("Provenance &amp; lineage", "from source to sealed strand") +
                '<div class="lineage">' +
                  lin("file", E(src.label) + " → chunk") +
                  lin("shield", "confidence-filter passed · secrets scrubbed") +
                  lin("engine", "embedded on-device (384-dim)") +
                  lin("cloak", "cloaked with vault key (Q, 24 reflections)") +
                  lin("seal", "sealed AES-256-GCM, committed") +
                "</div>" +
                '<hr class="rule"/>' +
                window.C.sectionHead("Version history", "tombstone-aware") +
                '<div class="stack-2">' +
                  ver("v3", "current", m.committedAt, false) +
                  ver("v2", "superseded", "2026-05-30T11:00:00Z", false) +
                  ver("v1", "tombstoned", "2026-05-26T09:00:00Z", true) +
                "</div>" +
              "</div>" +
            "</div>" +
            '<div class="stack-6">' +
              '<div class="panel stack-3">' +
                window.C.sectionHead("Crypto metadata") +
                facets +
              "</div>" +
              '<div class="panel stack-3">' +
                window.C.sectionHead("Recalled by", m.recallCount + " times total") +
                '<div class="stack">' + agents + "</div>" +
              "</div>" +
              '<div class="panel stack-3">' +
                '<div class="small muted">Forgetting writes a tombstone and deletes the ciphertext + cloaked vector. ' +
                'Because the server only ever held ciphertext, the deletion is genuine.</div>' +
                '<button class="btn btn--seal" data-forget="' + E(m.id) + '">' + icon("trash") + "Forget this memory</button>" +
              "</div>" +
            "</div>" +
          "</div>" +
        "</div>"
      );
    },
    mount(root, ctx) {
      const btn = qs(root, "[data-forget]");
      if (btn) btn.addEventListener("click", () => {
        window.App.confirm({
          title: "Forget this memory?",
          body: "This breaks the seal: the ciphertext and its cloaked vector are deleted, and a 30-day tombstone propagates to your trusted devices. This can’t be undone.",
          okLabel: "Break the seal",
          icon: "trash",
          onOk() {
            window.App.toast("Memory forgotten — tombstone propagating to 3 devices.", "seal");
            if (window.Basin) window.Basin.commit(window.innerWidth * 0.6);
            window.App.go("library");
          },
        });
      });
    },
  };
  function lin(ic, text) { return '<div class="lineage__step">' + icon(ic) + "<span class=\"small\">" + text + "</span></div>"; }
  function ver(v, label, iso, tomb) {
    return (
      '<div class="row row--between" style="padding:6px 0">' +
        '<span class="small">' + (tomb ? icon("trash") : icon("check")) + ' <b class="' + (tomb ? "dim" : "bright") + '">' + v + "</b> " +
          '<span class="' + (tomb ? "crimson" : "muted") + ' tiny">' + E(label) + "</span></span>" +
        '<span class="dim tiny mono">' + window.C.fmtDate(iso) + "</span>" +
      "</div>"
    );
  }

  /* ======================================================================
     REMEMBER (ingest)
     ====================================================================== */
  const SAMPLE_INGEST =
    "When deploying the marketing site, build with Node 22 and run firebase deploy with Node 24. " +
    "The Firebase token is AIzaSyD-EXAMPLE-9f2a41c0d7e85b13QwErTy and the admin key is sk-live-7d92f0a1b3c4. " +
    "Domain burnbar.ai is on Namecheap; project id is burnbar.";
  const SECRET_RE = /\b(AIza[0-9A-Za-z\-_]{10,}|sk-(?:live|test)-[0-9a-zA-Z]{6,}|[0-9a-f]{32,}|ghp_[0-9a-zA-Z]{20,})\b/g;

  const remember = {
    title: "Remember",
    render() {
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Remember · ingest", "Hand a memory to the basin.",
            "Watch the whole pipeline before anything is committed: low-value chunks are filtered, secrets are scrubbed " +
            "in front of you, near-duplicates are caught, then it’s embedded, cloaked, sealed — and only then does it descend into the pool.") +
          '<div class="ingest">' +
            '<div class="panel stack-4">' +
              window.C.sectionHead("What to remember") +
              '<textarea id="ingest-text" class="ingest-editor" aria-label="Memory text">' + E(SAMPLE_INGEST) + "</textarea>" +
              '<div class="stack-3">' +
                '<div class="meter__row"><span class="meter__label">Confidence threshold</span>' +
                  '<span class="meter__val" id="conf-val">0.55</span></div>' +
                '<input id="conf-slider" class="slider" type="range" min="0" max="100" value="55" aria-label="Confidence threshold" />' +
                '<p class="tiny dim">Chunks scoring below the threshold are dropped before embedding — keep the pool dense with signal.</p>' +
              "</div>" +
              '<hr class="rule"/>' +
              '<div class="stack-2">' +
                '<div class="eyebrow">Capture from</div>' +
                toggle("src-repo", "Repo docs", "Markdown + docs in connected repositories", true) +
                toggle("src-notes", "Notes", "Your personal notes folder", true) +
                toggle("src-chat", "Chat-derived", "Salient facts distilled from assistant + CLI chats", false) +
              "</div>" +
              '<button class="btn btn--primary" id="commit-btn" style="width:100%;justify-content:center">' + icon("seal") + "Seal this memory</button>" +
            "</div>" +
            '<div class="panel stack-4">' +
              window.C.sectionHead("The pipeline", "live, on your device") +
              '<div id="redact-preview" class="panel--quiet" style="padding:var(--space-4);border-radius:var(--radius-md);border:1px solid var(--color-glass-line)"></div>' +
              '<div id="dedup-note"></div>' +
              '<div id="ingest-pipeline"></div>' +
            "</div>" +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      const text = qs(root, "#ingest-text");
      const preview = qs(root, "#redact-preview");
      const dedup = qs(root, "#dedup-note");
      const pipeWrap = qs(root, "#ingest-pipeline");
      const confSlider = qs(root, "#conf-slider");
      const confVal = qs(root, "#conf-val");
      const commit = qs(root, "#commit-btn");
      let committed = false;

      function redactPreview() {
        const raw = text.value;
        const secrets = raw.match(SECRET_RE) || [];
        let safe = E(raw);
        secrets.forEach((s) => {
          safe = safe.replace(E(s), '<mark>' + "•".repeat(Math.min(18, s.length)) + "</mark>");
        });
        preview.innerHTML =
          '<div class="row" style="margin-bottom:var(--space-2)"><span class="eyebrow">Secret-redaction preview</span>' +
            '<span class="spacer"></span>' +
            (secrets.length
              ? '<span class="redact-note">' + icon("alert") + secrets.length + " secret" + (secrets.length > 1 ? "s" : "") + " scrubbed</span>"
              : '<span class="chip chip--seal tiny">' + icon("check") + "clean</span>") + "</div>" +
          '<div class="redact small" style="line-height:1.6">' + safe + "</div>";
        return secrets.length;
      }

      function dedupCheck() {
        const ranked = R.rank(text.value, P.MEMORIES, 1);
        if (ranked.length && ranked[0].score > 0.18) {
          dedup.innerHTML =
            '<div class="row" style="gap:8px;padding:var(--space-3);border:1px dashed var(--color-glass-line-bright);border-radius:var(--radius-md)">' +
              icon("dedup") +
              '<span class="small">Near a memory you already hold — <b class="bright">' + E(ranked[0].mem.title) + "</b> " +
              '<span class="mono teal">' + ranked[0].score.toFixed(2) + "</span> similar. It’ll merge, not duplicate.</span></div>";
        } else { dedup.innerHTML = ""; }
      }

      function drawPipeline(secrets, conf) {
        pipeWrap.innerHTML = window.C.pipeline([
          { icon: "shield", title: "Confidence filter", desc: "Threshold " + conf.toFixed(2) + " — this chunk scores 0.81, kept.", where: "on your device", done: true },
          { icon: "alert", title: "Secret redaction", desc: secrets ? secrets + " secret value(s) stripped before embedding." : "No secrets detected.", where: "on your device", color: secrets ? "var(--color-seal-crimson)" : "var(--color-tier-end-to-end)", done: true },
          { icon: "dedup", title: "Dedup against existing", desc: "Vault-keyed HMAC + cosine vs your sealed set.", where: "on your device", done: true },
          { icon: "engine", title: "Embed", desc: "bge-small-en-v1.5 → 384-dim vector.", where: "on your device", done: committed },
          { icon: "cloak", title: "Cloak", desc: "Orthonormal Q (24 reflections) — basis hidden, byte-distinct.", where: "on your device", color: "var(--color-tier-zero-access)", done: committed },
          { icon: "seal", title: "Seal", desc: "AES-256-GCM under your vault key.", where: "on your device", done: committed },
          { icon: "basin", title: "Commit", desc: committed ? "Descended into the pool." : "Ready — press seal to commit.", where: "cloud holds ciphertext only", active: !committed, done: committed },
        ]);
      }

      function refresh() {
        const secrets = redactPreview();
        dedupCheck();
        drawPipeline(secrets, parseInt(confSlider.value, 10) / 100);
      }
      text.addEventListener("input", refresh);
      confSlider.addEventListener("input", () => {
        confVal.textContent = (parseInt(confSlider.value, 10) / 100).toFixed(2);
        drawPipeline((text.value.match(SECRET_RE) || []).length, parseInt(confSlider.value, 10) / 100);
      });
      qsa(root, ".switch").forEach((s) => s.addEventListener("click", () => s.classList.toggle("is-on")));
      commit.addEventListener("click", () => {
        committed = true;
        refresh();
        commit.innerHTML = icon("check") + "Sealed &amp; committed";
        commit.classList.remove("btn--primary"); commit.classList.add("btn--ghost");
        if (window.Basin) window.Basin.commit(window.innerWidth * 0.72);
        window.App.toast("Memory sealed and committed — the server holds only ciphertext.", "default");
        setTimeout(() => { committed = false; commit.innerHTML = icon("seal") + "Seal this memory"; commit.classList.add("btn--primary"); commit.classList.remove("btn--ghost"); refresh(); }, 4000);
      });
      refresh();
    },
  };
  function toggle(id, label, sub, on) {
    return (
      '<div class="toggle"><div class="toggle__text">' + E(label) + "<small>" + E(sub) + "</small></div>" +
      '<button class="switch ' + (on ? "is-on" : "") + '" id="' + id + '" role="switch" aria-checked="' + !!on + '" aria-label="' + E(label) + '"></button></div>'
    );
  }

  /* ======================================================================
     THE CLOAK (transparency centerpiece)
     ====================================================================== */
  const cloak = {
    title: "The Cloak",
    render() {
      const opts = P.MEMORIES.slice(0, 6).map((m, i) => '<option value="' + m.id + '"' + (i === 0 ? " selected" : "") + ">" + E(m.title) + "</option>").join("");
      return (
        '<div class="surface__inner stack-8">' +
          window.C.surfaceHero("The Cloak · transparency", "What you see vs. what the server sees.",
            "This is the trust centerpiece, told honestly. On the left, a memory as you read it. On the right, exactly what the cloud holds: " +
            "a cloaked vector and sealed ciphertext it cannot read — plus the only two plaintext facets, <span class='teal'>sourceKind</span> and <span class='teal'>byteCount</span>.") +
          '<div class="row"><label class="small muted">Inspect memory&nbsp;</label>' +
            '<select id="cloak-pick" class="btn btn--ghost btn--sm" style="cursor:pointer">' + opts + "</select></div>" +
          '<div class="cloak-split">' +
            '<div class="cloak-pane cloak-pane--yours">' +
              '<div class="cloak-pane__tag">' + icon("eye") + "What you see · on your device</div>" +
              '<div id="cloak-plain" class="memory-body" style="font-size:14px"></div>' +
              '<hr class="rule"/>' +
              '<div class="small muted" style="margin-bottom:8px">Your private embedding — never uploaded</div>' +
              '<canvas class="cloak-scatter" id="scatter-raw" width="520" height="150"></canvas>' +
            "</div>" +
            '<div class="cloak-pane cloak-pane--server">' +
              '<div class="cloak-pane__tag">' + icon("cloak") + "What the server sees · cloud</div>" +
              '<div class="small muted" style="margin-bottom:8px">Cloaked 384-dim vector (shown in 2D)</div>' +
              '<canvas class="cloak-scatter" id="scatter-cloak" width="520" height="150"></canvas>' +
              '<div class="stack-2" style="margin:var(--space-4) 0">' +
                window.C.facet("sourceKind", "—", false) +
                window.C.facet("byteCount", "—", false) +
              "</div>" +
              '<div class="small muted" style="margin-bottom:6px">Sealed ciphertext (AES-256-GCM)</div>' +
              '<div class="cipher" id="cloak-cipher"></div>' +
            "</div>" +
          "</div>" +

          '<div class="panel stack-6">' +
            window.C.sectionHead("Honest accounting", "post-remediation truth — not a sales pitch") +
            '<div class="grid grid--2">' +
              '<div class="honesty"><h4>' + icon("check") + " What the cloak protects</h4>" +
                '<ul class="small muted" style="padding-left:18px;line-height:1.7">' +
                  "<li><b class='teal'>Hides the public-model basis.</b> Stored vectors aren’t in raw bge space, so off-the-shelf inversion can’t be pointed at them directly.</li>" +
                  "<li><b class='teal'>Per-user distinct bytes.</b> The same note under two members’ keys stores differently (relative L2 ≈ 0.74) — exact-match cross-tenant joins find nothing.</li>" +
                "</ul></div>" +
              '<div class="honesty" style="border-color:var(--color-tier-zero-access)"><h4 class="slate">' + icon("info") + " What it leaks (accepted)</h4>" +
                '<ul class="small muted" style="padding-left:18px;line-height:1.7">' +
                  "<li><b class='slate'>Relative geometry.</b> Cosine is preserved exactly, so the server can compute your kNN graph, clusters, and near-dups — never the content.</li>" +
                  "<li><b class='slate'>Partial cross-tenant linkage.</b> At 24 reflections, cross-tenant cosine ≈ 0.77 — a coarse “same-item” signal, not identity.</li>" +
                "</ul></div>" +
            "</div>" +
            '<div class="grid grid--2">' +
              '<div class="stack-3"><div class="eyebrow">Measured, live, in the 2D demo above</div>' +
                '<div class="facet"><span class="facet__k">distance preserved (max err)</span><span class="facet__v teal" id="readout-dist">—</span></div>' +
                '<div class="facet"><span class="facet__k">cross-tenant cosine (same item)</span><span class="facet__v amber" id="readout-cross">—</span></div>' +
                '<p class="tiny dim">2D is illustrative; the shipped cloak is 384-dim with 24 Householder reflections. The invariants are the same.</p>' +
              "</div>" +
              '<div class="stack-3"><div class="eyebrow">Cross-tenant cosine vs. reflection count <span class="dim">(measured)</span></div>' +
                '<div class="reflect-chart">' + P.REFLECTIONS.map((r) =>
                  '<div class="reflect-row' + (r.shipped ? " is-shipped" : "") + '">' +
                    '<span class="reflect-row__k">k=<b>' + r.k + "</b>" + (r.shipped ? " shipped" : "") + "</span>" +
                    '<span class="reflect-row__bar"><span class="reflect-row__fill" style="width:' + Math.round(r.cos * 100) + '%"></span></span>' +
                    '<span class="reflect-row__v">' + r.cos.toFixed(2) + "</span>" +
                  "</div>"
                ).join("") + "</div>" +
                '<p class="tiny dim">Raising k toward the dimension drives cross-tenant cosine to ≈ 0 — a versioned re-cloak migration, tracked, not yet shipped.</p>' +
              "</div>" +
            "</div>" +
            '<div class="row"><a class="inline-link small" href="' + P.LEAKAGE_DOC + '" target="_blank" rel="noopener">' + icon("link") + ' Read the full leakage analysis →</a></div>' +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      const pick = qs(root, "#cloak-pick");
      const demo = R.cloakDemo(9);
      drawScatter(qs(root, "#scatter-raw"), demo.raw, "199,207,221", true);
      drawScatter(qs(root, "#scatter-cloak"), demo.cloakA, "60,214,192", true);
      qs(root, "#readout-dist").textContent = "±" + demo.distErr.toExponential(1) + " (≈ 0)";
      qs(root, "#readout-cross").textContent = demo.crossCos.toFixed(2);

      function show(id) {
        const m = P.memById(id);
        qs(root, "#cloak-plain").textContent = m.body;
        const facets = qsa(root, ".cloak-pane--server .facet");
        facets[0].querySelector(".facet__v").textContent = m.sourceKind;
        facets[1].querySelector(".facet__v").textContent = m.byteCount + " B";
        const cipherEl = qs(root, "#cloak-cipher");
        cipherEl.classList.add("frost"); cipherEl.style.opacity = "0";
        cipherEl.textContent = cipherBlock(m.id + m.body, 6);
        requestAnimationFrame(() => { cipherEl.style.transition = "opacity var(--motion-frost-flip)"; cipherEl.style.opacity = "1"; });
      }
      pick.addEventListener("change", () => show(pick.value));
      show(pick.value);
    },
  };

  function drawScatter(canvas, pts, rgb, lines) {
    if (!canvas) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = canvas.width = canvas.clientWidth * dpr;
    const h = canvas.height = canvas.clientHeight * dpr;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, w, h);
    const pad = 24 * dpr;
    const map = ([x, y]) => [pad + ((x + 1) / 2) * (w - pad * 2), pad + ((y + 1) / 2) * (h - pad * 2)];
    const P2 = pts.map(map);
    if (lines) {
      ctx.strokeStyle = "rgba(" + rgb + ",0.18)";
      ctx.lineWidth = 1;
      for (let i = 0; i < P2.length; i++) {
        // connect to 2 nearest (the preserved kNN graph)
        const d = P2.map((p, j) => [j, Math.hypot(P2[i][0] - p[0], P2[i][1] - p[1])]).filter((x) => x[0] !== i).sort((a, b) => a[1] - b[1]);
        for (let k = 0; k < 2 && k < d.length; k++) {
          ctx.beginPath(); ctx.moveTo(P2[i][0], P2[i][1]); ctx.lineTo(P2[d[k][0]][0], P2[d[k][0]][1]); ctx.stroke();
        }
      }
    }
    P2.forEach((p) => {
      const g = ctx.createRadialGradient(p[0], p[1], 0, p[0], p[1], 9 * dpr);
      g.addColorStop(0, "rgba(" + rgb + ",1)");
      g.addColorStop(1, "rgba(" + rgb + ",0)");
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.arc(p[0], p[1], 9 * dpr, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = "rgba(" + rgb + ",1)";
      ctx.beginPath(); ctx.arc(p[0], p[1], 2.4 * dpr, 0, Math.PI * 2); ctx.fill();
    });
  }

  /* ======================================================================
     DATA & PRIVACY CONTROL CENTER
     ====================================================================== */
  const privacy = {
    title: "Data & Privacy",
    render() {
      const order = ["end_to_end", "zero_access", "server_readable"];
      const byTier = {};
      P.DOMAINS.forEach((d) => (byTier[d.tier] = byTier[d.tier] || []).push(d));
      const groups = order.map((tier) => {
        const t = P.TIERS[tier];
        return (
          '<div class="library-group">' +
            '<div class="library-group__head">' +
              '<span class="library-group__title" style="color:' + t.color + '">' +
                '<span class="tier__gem" style="--tier-c:' + t.color + '"></span>' + E(t.label) + "</span>" +
              '<span class="library-group__count">' + (byTier[tier] || []).length + " domains</span>" +
              '<span class="library-group__line"></span>' +
            "</div>" +
            '<p class="small muted" style="margin-bottom:var(--space-3)">' + E(t.blurb) + "</p>" +
            '<div class="stack-3">' + (byTier[tier] || []).map(window.C.domainRow).join("") + "</div>" +
          "</div>"
        );
      }).join("");

      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Control Center · every domain", "What the server can and cannot see.",
            "Every kind of data BurnBar holds, with its honest encryption tier. No domain claims more than it earns — " +
            "<span class='amber'>chat is server-readable</span>, never labeled end-to-end.") +
          '<div class="panel stack-4">' + groups + "</div>" +
          '<div class="panel stack-4" style="border-color:rgba(197,34,31,0.3)">' +
            window.C.sectionHead("Account-wide actions") +
            '<div class="row">' +
              '<button class="btn" data-export>' + icon("export") + "Export my data</button>" +
              '<span class="spacer"></span>' +
              '<button class="btn btn--seal" data-panic>' + icon("alert") + "Revoke all access</button>" +
            "</div>" +
            '<p class="tiny dim">Revoke-all untrusts every device and agent, rotates the wrapped vault key, and forces re-approval ' +
            'on next sign-in. Your sealed data stays sealed — this cuts every key path to it.</p>' +
          "</div>" +
          '<div id="domain-drawer"></div>' +
        "</div>"
      );
    },
    mount(root) {
      const drawer = qs(root, "#domain-drawer");
      qsa(root, "[data-domain]").forEach((b) => b.addEventListener("click", () => openDomain(b.dataset.domain, drawer, root)));
      qs(root, "[data-export]").addEventListener("click", () =>
        window.App.toast("Export started — you’ll get a signed, client-decryptable archive.", "default"));
      qs(root, "[data-panic]").addEventListener("click", () =>
        window.App.confirm({
          title: "Revoke all access?",
          body: "This untrusts every device and agent, rotates your wrapped vault key, and requires fresh approval everywhere. Use it if a device is lost or compromised.",
          okLabel: "Revoke everything",
          icon: "alert",
          requireType: "REVOKE",
          onOk() { window.App.toast("All access revoked. Re-approve a device to unseal again.", "seal"); },
        }));
    },
  };

  function openDomain(id, drawer, root) {
    const d = P.domainById(id);
    const t = P.TIERS[d.tier];
    drawer.innerHTML =
      '<div class="panel stack-4" style="border-color:' + t.color + '40">' +
        '<div class="row"><span class="domain__icon" style="--tier-c:' + t.color + '">' + icon(d.icon) + "</span>" +
          '<div><div class="row" style="gap:8px"><h3>' + E(d.title) + "</h3>" + window.C.tierBadge(d.tier, { sm: true }) + "</div>" +
          '<p class="small muted">' + E(d.summary) + "</p></div>" +
          '<span class="spacer"></span><button class="btn btn--ghost btn--sm" data-closedrawer>' + icon("x") + "</button></div>" +
        '<div class="grid grid--2">' +
          '<div><div class="domain__see-h amber">Server sees</div><div class="stack-2" style="margin-top:8px">' +
            d.serverSees.map((s) => window.C.facet("plaintext", s)).join("") + "</div></div>" +
          '<div><div class="domain__see-h teal">Only your devices</div><div class="stack-2" style="margin-top:8px">' +
            (d.deviceOnly.length ? d.deviceOnly.map((s) => window.C.facet("sealed", s, true)).join("") : '<p class="small dim">Nothing device-only — this domain is operational metadata.</p>') + "</div></div>" +
        "</div>" +
        '<div class="row">' +
          (d.actions.includes("export") ? '<button class="btn btn--sm" data-d-export>' + icon("export") + "Export</button>" : "") +
          (d.actions.includes("delete") ? '<button class="btn btn--sm btn--seal" data-d-delete>' + icon("trash") + "Delete this domain</button>" : "") +
          (d.actions.includes("revoke") ? '<button class="btn btn--sm btn--seal" data-d-delete>' + icon("lock") + "Revoke</button>" : "") +
          '<span class="spacer"></span><span class="dim tiny">Retention: ' + E(d.retention) + "</span>" +
        "</div>" +
      "</div>";
    drawer.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "center" });
    qs(drawer, "[data-closedrawer]").addEventListener("click", () => (drawer.innerHTML = ""));
    const del = qs(drawer, "[data-d-delete]");
    if (del) del.addEventListener("click", () =>
      window.App.confirm({
        title: "Delete " + d.title + "?",
        body: "Permanently removes this domain’s data. " + (d.tier === "end_to_end" ? "Because it’s end-to-end sealed, deletion is genuine ciphertext deletion." : "Operational copies are purged from BurnBar’s store."),
        okLabel: "Delete domain", icon: "trash",
        onOk() { window.App.toast(d.title + " deleted.", "seal"); drawer.innerHTML = ""; },
      }));
    const exp = qs(drawer, "[data-d-export]");
    if (exp) exp.addEventListener("click", () => window.App.toast("Exporting " + d.title + "…", "default"));
  }

  /* ======================================================================
     AUDIT TIMELINE
     ====================================================================== */
  const AUDIT_EVENTS = [
    { actor: "Mac Studio", action: "Vault unlocked", domain: "device_trust_keys", time: "2026-06-02T09:01:00Z", detail: "Biometric unlock on trusted device", kind: "ok" },
    { actor: "Claude (MCP)", action: "Recalled 4 strands", domain: "pensieve", time: "2026-06-02T09:14:00Z", detail: "searchKnowledge · scopes: read", kind: "ok" },
    { actor: "OpenTimestamps", action: "Daily anchor committed", domain: "audit_timeline", time: "2026-06-02T00:00:00Z", detail: "Bitcoin attestation of chain head", kind: "anchor" },
    { actor: "iPhone 15 Pro", action: "Committed 12 memories", domain: "pensieve", time: "2026-06-02T11:42:00Z", detail: "notes sync · sealed on device", kind: "ok" },
    { actor: "Codex (MCP)", action: "Grant issued", domain: "external_mcp", time: "2026-06-02T12:03:00Z", detail: "scopes: read · expires 24h", kind: "ok" },
    { actor: "You", action: "Forgot 1 memory", domain: "pensieve", time: "2026-06-02T14:20:00Z", detail: "tombstone written · 30-day GC", kind: "seal" },
    { actor: "MacBook Air", action: "Trust requested", domain: "device_trust_keys", time: "2026-06-02T18:58:00Z", detail: "awaiting your approval", kind: "ok" },
  ];

  const audit = {
    title: "Audit",
    render() {
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Audit · tamper-evident", "A thread you can prove.",
            "Every privacy action is a link in a SHA-256 hash chain. Edit or remove any link and verification fails, " +
            "visibly. Once a day the head is anchored with OpenTimestamps — even we can’t quietly rewrite it.") +
          '<div class="panel stack-4">' +
            '<div class="row">' +
              '<button class="btn btn--primary" id="verify-btn">' + icon("shield") + "Verify this chain</button>" +
              '<button class="btn btn--ghost" id="tamper-btn">' + icon("alert") + "Simulate tampering</button>" +
              '<button class="btn btn--ghost" id="reset-btn" hidden>' + icon("refresh") + "Restore</button>" +
              '<span class="spacer"></span><span id="verify-status" class="small muted"></span>' +
            "</div>" +
            '<div id="audit-thread" class="audit"></div>' +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      let nodes = R.buildChain(AUDIT_EVENTS);
      const thread = qs(root, "#audit-thread");
      const status = qs(root, "#verify-status");
      const resetBtn = qs(root, "#reset-btn");
      let brokenAt = -1;

      function draw() {
        thread.innerHTML = nodes.map((n, i) => {
          const cls = n.kind === "anchor" ? " audit-node--anchor" : n.kind === "seal" ? " audit-node--seal" : "";
          const broke = brokenAt >= 0 && i >= brokenAt ? " is-broken" : "";
          return (
            '<div class="audit-node' + cls + broke + '">' +
              '<span class="audit-node__dot"></span>' +
              '<div class="audit-node__head">' +
                '<span class="audit-node__action">' + (n.kind === "anchor" ? icon("anchor") + " " : "") + E(n.action) + "</span>" +
                '<span class="chip tiny">' + E(n.actor) + "</span>" +
                '<span class="audit-node__time">' + window.C.fmtDate(n.time) + "</span>" +
              "</div>" +
              '<div class="audit-node__detail">' + E(n.detail) + " · <span class='dim'>" + E(n.domain) + "</span></div>" +
              '<div class="audit-node__hash">' + icon("link") +
                "<span>" + n.hash.slice(0, 18) + "…</span>" +
                '<span class="link-prev">← prev ' + n.prevHash.slice(0, 10) + "…</span>" +
                (broke ? ' <span class="crimson tiny">' + icon("alert") + " chain broken here</span>" : "") +
              "</div>" +
            "</div>"
          );
        }).join("");
      }
      qs(root, "#verify-btn").addEventListener("click", () => {
        const i = R.verifyChain(nodes);
        brokenAt = i;
        if (i < 0) { status.innerHTML = '<span class="teal">' + icon("check") + " Chain intact — " + nodes.length + " links verified against the anchor.</span>"; }
        else { status.innerHTML = '<span class="crimson">' + icon("alert") + " Verification failed at link " + (i + 1) + " — the log was altered.</span>"; }
        draw();
      });
      qs(root, "#tamper-btn").addEventListener("click", () => {
        // silently edit a middle node's detail without re-hashing — the tamper
        nodes = R.buildChain(AUDIT_EVENTS);
        nodes[3] = Object.assign({}, nodes[3], { detail: "notes sync · 9 memories (altered)", action: "Committed 9 memories" });
        brokenAt = -1;
        status.innerHTML = '<span class="amber">' + icon("info") + " A link was quietly altered. Now verify the chain.</span>";
        resetBtn.hidden = false;
        draw();
      });
      resetBtn.addEventListener("click", () => {
        nodes = R.buildChain(AUDIT_EVENTS); brokenAt = -1; resetBtn.hidden = true;
        status.innerHTML = '<span class="muted">Restored to the genuine chain.</span>';
        draw();
      });
      draw();
    },
  };

  /* ======================================================================
     VAULT & DEVICES
     ====================================================================== */
  const vault = {
    title: "Vault & Devices",
    render() {
      const devices = P.DEVICES.map((d) =>
        '<div class="domain" style="grid-template-columns:40px 1fr auto">' +
          '<span class="domain__icon" style="--tier-c:' + (d.canDecrypt ? "var(--color-tier-end-to-end)" : "var(--color-tier-zero-access)") + '">' + icon("device") + "</span>" +
          '<div class="domain__body"><div class="domain__title"><span class="domain__name">' + E(d.name) + "</span>" +
            (d.current ? '<span class="chip chip--seal tiny">this device</span>' : "") +
            (d.canDecrypt ? '<span class="chip chip--seal tiny">' + icon("unlock") + "can decrypt</span>" : '<span class="chip tiny">' + icon("lock") + "no key</span>") + "</div>" +
            '<div class="domain__summary">' + E(d.kind) + ' · <span class="mono tiny dim">' + E(d.fp) + "</span></div></div>" +
          '<div class="domain__aside"><span class="dim tiny">seen ' + E(d.lastSeen) + "</span>" +
            (d.trusted
              ? (d.current ? "" : '<button class="btn btn--sm btn--seal" data-revoke="' + d.id + '">Revoke</button>')
              : '<button class="btn btn--sm btn--ember" data-approve="' + d.id + '">Approve</button>') + "</div>" +
        "</div>"
      ).join("");

      const recovery = P.RECOVERY.map((r) =>
        '<div class="toggle"><div class="toggle__text">' +
          (r.ok ? '<span class="teal">' + icon("check") + "</span> " : '<span class="amber">' + icon("alert") + "</span> ") +
          E(r.name) + "<small>" + E(r.detail) + "</small></div>" +
          (r.ok ? '<span class="chip chip--seal tiny">' + E(r.status) + "</span>" : '<button class="btn btn--sm btn--ember">Set up</button>") +
        "</div>"
      ).join("");

      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Vault & devices", "The keys, and who holds them.",
            "Your vault key never leaves your devices. The cloud holds only wrapped (ciphertext) key blobs and trust state. " +
            "Add a device and an existing one re-wraps the key to it — after you approve.") +
          '<div class="grid recall-layout">' +
            '<div class="panel stack-4">' +
              window.C.sectionHead("Trusted devices", P.DEVICES.filter((d) => d.canDecrypt).length + " can decrypt") +
              '<div class="stack-3">' + devices + "</div>" +
              '<button class="btn btn--ghost btn--sm" data-add>' + icon("remember") + "Add a device</button>" +
            "</div>" +
            '<div class="stack-6">' +
              '<div class="panel stack-4">' +
                window.C.sectionHead("Encrypted cloud backup") +
                '<div class="row"><span class="live-pulse__beacon"></span><span class="small bright">Vault-key wrapping active</span></div>' +
                window.C.facet("wrapped key blobs", "3 devices · cloud_vault_key_wrappers") +
                window.C.facet("vault key", "Keychain / 0600 file · never uploaded", true) +
                '<div class="honesty" style="border-color:var(--color-tier-zero-access)"><h4 class="slate">' + icon("info") + " Honest status</h4>" +
                  '<p class="small muted">Encryption-at-rest for the cross-device chat mirror is <b class="slate">in progress</b> — a tracked hardening, ' +
                  'not yet active. We label it server-readable until it ships, rather than over-claim.</p></div>' +
              "</div>" +
              '<div class="panel stack-3">' +
                window.C.sectionHead("Recovery methods", "survive total device loss") +
                recovery +
              "</div>" +
            "</div>" +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      qsa(root, "[data-approve]").forEach((b) => b.addEventListener("click", () => {
        const d = P.DEVICES.find((x) => x.id === b.dataset.approve);
        window.App.confirm({
          title: "Trust " + d.name + "?", icon: "key", tone: "ember",
          body: "An existing trusted device will re-wrap your vault key to " + d.name + " (" + d.fp + "). Only approve devices you recognize.",
          okLabel: "Approve & re-wrap key",
          onOk() { window.App.toast(d.name + " trusted — vault key re-wrapped.", "ember"); window.App.go("vault"); },
        });
      }));
      qsa(root, "[data-revoke]").forEach((b) => b.addEventListener("click", () => {
        const d = P.DEVICES.find((x) => x.id === b.dataset.revoke);
        window.App.confirm({
          title: "Revoke " + d.name + "?", icon: "lock",
          body: "Removes its key wrapping immediately. It can no longer decrypt anything until re-approved.",
          okLabel: "Revoke device",
          onOk() { window.App.toast(d.name + " revoked.", "seal"); window.App.go("vault"); },
        });
      }));
      qs(root, "[data-add]").addEventListener("click", () => window.App.toast("Open Pensieve on the new device and scan the pairing code.", "default"));
    },
  };

  /* ======================================================================
     ENGINE
     ====================================================================== */
  const engine = {
    title: "Engine",
    render() {
      const e = P.ENGINE;
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Engine · how recall works", "The machinery, demystified.",
            "No jargon, no hand-waving. Here’s exactly how a question becomes the right memory — and why the cloud can do the search without ever reading it.") +
          '<div class="grid grid--stats">' +
            window.C.stat(e.dim, "vector dimension", { unit: "dim" }) +
            window.C.stat(e.metric, "similarity metric") +
            window.C.stat("on-device", "where embedding runs") +
            window.C.stat("cents", "per-member cost / mo", { unit: "≈" }) +
          "</div>" +
          '<div class="grid grid--2">' +
            engineCard("engine", "Embed", "bge-small-en-v1.5", "Your text becomes a 384-number fingerprint of its meaning — computed on your device, never sent as text. Similar ideas land near each other.") +
            engineCard("cloak", "Cloak", e.cloak, "That fingerprint is rotated by a secret matrix only your vault key can build. The cloud sees coordinates in a frame it can’t read — but distances survive, so search still works.") +
            engineCard("seal", "Seal", e.seal, "The original text is locked with AES-256-GCM under your vault key. The cloud stores only the locked box. Deletion is genuine — there’s no spare copy.") +
            engineCard("waves", "Search", e.index, "When you ask, your cloaked question is compared to cloaked memories by cosine. The cloud ranks boxes it can’t open; your device opens only the winners.") +
          "</div>" +
          '<div class="panel stack-4">' +
            window.C.sectionHead("Forward-looking", "semantic memory is maturing") +
            '<div class="coming"><span class="coming__tag">' + icon("sparkle") + " Parity tracked</span>" +
              '<p class="small muted" style="margin-top:12px;max-width:60ch;margin-inline:auto">' + E(e.parity) + ". " +
              "Upgrading the embedder or raising the cloak’s reflection count are versioned migrations behind " +
              "<span class='mono teal'>embeddingModelVersion</span> — existing vectors re-cloak cleanly, byte-identical to the Swift mirror.</p></div>" +
          "</div>" +
        "</div>"
      );
    },
  };
  function engineCard(ic, kicker, value, body) {
    return (
      '<div class="panel stack-3">' +
        '<div class="row"><span class="domain__icon" style="--tier-c:var(--color-tier-end-to-end)">' + icon(ic) + "</span>" +
          '<div><div class="eyebrow">' + E(kicker) + '</div><div class="mono small teal">' + E(value) + "</div></div></div>" +
        '<p class="small muted">' + E(body) + "</p>" +
      "</div>"
    );
  }

  /* ======================================================================
     SETTINGS
     ====================================================================== */
  const settings = {
    title: "Settings",
    render() {
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Settings", "Tune what the basin keeps.", "") +
          '<div class="grid grid--2">' +
            '<div class="panel stack-3">' + window.C.sectionHead("What to remember") +
              toggle("set-repo", "Repo docs", "Markdown & docs from connected repositories", true) +
              toggle("set-notes", "Notes", "Your personal notes folder", true) +
              toggle("set-chat", "Chat-derived", "Salient facts distilled from chats (server-readable source)", false) +
            "</div>" +
            '<div class="panel stack-3">' + window.C.sectionHead("Confidence & retention") +
              '<div class="meter__row"><span class="meter__label">Confidence threshold</span><span class="meter__val" id="set-conf">0.55</span></div>' +
              '<input class="slider" type="range" min="0" max="100" value="55" id="set-conf-slider" aria-label="Confidence threshold"/>' +
              '<hr class="rule"/>' +
              '<div class="toggle"><div class="toggle__text">Tombstone window<small>How long deletes propagate before GC</small></div><span class="chip tiny mono">30 days</span></div>' +
              '<div class="toggle"><div class="toggle__text">Auto-dedup<small>Merge near-duplicates on commit</small></div>' + '<button class="switch is-on" role="switch" aria-checked="true" aria-label="Auto-dedup"></button></div>' +
            "</div>" +
            '<div class="panel stack-3">' + window.C.sectionHead("Redaction rules") +
              '<p class="small muted">Patterns scrubbed on-device before embedding. Add your own — they never leave the device.</p>' +
              '<div class="stack-2">' +
                window.C.facet("api keys", "AIza… · sk-live-… · ghp_…") +
                window.C.facet("private keys", "-----BEGIN … PRIVATE KEY-----") +
                window.C.facet("high entropy", "≥ 32 hex / base64 runs") +
              "</div>" +
            "</div>" +
            '<div class="panel stack-3">' + window.C.sectionHead("Per-domain privacy") +
              '<p class="small muted">Jump to the Control Center to see every domain’s tier and what the server can read.</p>' +
              '<button class="btn btn--ghost btn--sm" data-go="privacy">' + icon("shield") + "Open Control Center</button>" +
            "</div>" +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      qsa(root, ".switch").forEach((s) => s.addEventListener("click", () => { const on = !s.classList.contains("is-on"); s.classList.toggle("is-on", on); s.setAttribute("aria-checked", on); }));
      const slider = qs(root, "#set-conf-slider"), val = qs(root, "#set-conf");
      if (slider) slider.addEventListener("input", () => (val.textContent = (parseInt(slider.value, 10) / 100).toFixed(2)));
    },
  };

  /* ======================================================================
     CONSTELLATION (forward-looking)
     ====================================================================== */
  const constellation = {
    title: "Constellation",
    render() {
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Memory Constellation · beta", "Your knowledge as a sky.",
            "Memories that mean similar things sit near each other. Pan and zoom through the clusters. " +
            "(The honest footnote: this exact geometry — who’s near whom — is the one thing the cloak preserves and the server can see.)") +
          '<div class="row const-legend">' +
            legend("var(--color-tier-end-to-end)", "Repo docs") + legend("var(--color-mercury-bright)", "Notes") + legend("var(--color-tier-server-readable)", "Chat-derived") +
            '<span class="spacer"></span><span class="dim tiny">drag to pan · scroll to zoom</span>' +
          "</div>" +
          '<div style="position:relative">' +
            '<canvas class="constellation-canvas" id="const-canvas"></canvas>' +
            '<div id="const-tip" class="chip" style="position:absolute;pointer-events:none;opacity:0;transition:opacity .15s"></div>' +
          "</div>" +
        "</div>"
      );
    },
    mount(root) {
      const canvas = qs(root, "#const-canvas");
      const tip = qs(root, "#const-tip");
      const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      // project memories to 2D via similarity to two anchors
      const a1 = P.memById("m-cloak-geometry"), a2 = P.memById("m-domain");
      function sim(m, a) { const q = R.rank(a.title + " " + a.body, [m], 1); return q.length ? q[0].score : 0; }
      const nodes = P.MEMORIES.map((m) => {
        const x = sim(m, a1), y = sim(m, a2);
        return { m, bx: (x - 0.15) * 2.6 - 0.7, by: (y - 0.1) * 2.6 - 0.7,
          color: m.sourceKind === "repo_docs" ? "60,214,192" : m.sourceKind === "notes" ? "199,207,221" : "253,196,44",
          r: 4 + Math.min(10, m.recallCount / 6) };
      });
      let scale = 1, ox = 0, oy = 0, drag = null, t = 0;
      function resize() {
        const dpr = Math.min(2, window.devicePixelRatio || 1);
        canvas.width = canvas.clientWidth * dpr; canvas.height = canvas.clientHeight * dpr;
        canvas.getContext("2d").setTransform(dpr, 0, 0, dpr, 0, 0);
      }
      function toScreen(n) {
        const w = canvas.clientWidth, h = canvas.clientHeight;
        return [w / 2 + (n.bx * w * 0.32 + ox) * scale, h / 2 + (n.by * h * 0.32 + oy) * scale];
      }
      function draw() {
        const ctx = canvas.getContext("2d");
        const w = canvas.clientWidth, h = canvas.clientHeight;
        ctx.clearRect(0, 0, w, h);
        const pts = nodes.map(toScreen);
        // edges to nearest neighbors
        ctx.lineWidth = 1;
        for (let i = 0; i < nodes.length; i++) {
          const d = nodes.map((n, j) => [j, Math.hypot(nodes[i].bx - n.bx, nodes[i].by - n.by)]).filter((x) => x[0] !== i).sort((a, b) => a[1] - b[1]);
          for (let k = 0; k < 2; k++) {
            const j = d[k][0];
            ctx.strokeStyle = "rgba(199,207,221," + Math.max(0, 0.16 - d[k][1] * 0.08) + ")";
            ctx.beginPath(); ctx.moveTo(pts[i][0], pts[i][1]); ctx.lineTo(pts[j][0], pts[j][1]); ctx.stroke();
          }
        }
        nodes.forEach((n, i) => {
          const [x, y] = pts[i];
          const pulse = reduce ? 1 : 1 + Math.sin(t / 30 + i) * 0.12;
          const rr = n.r * scale * pulse;
          const g = ctx.createRadialGradient(x, y, 0, x, y, rr * 2.4);
          g.addColorStop(0, "rgba(" + n.color + ",0.9)");
          g.addColorStop(1, "rgba(" + n.color + ",0)");
          ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, rr * 2.4, 0, Math.PI * 2); ctx.fill();
          ctx.fillStyle = "rgba(" + n.color + ",1)"; ctx.beginPath(); ctx.arc(x, y, rr * 0.6, 0, Math.PI * 2); ctx.fill();
        });
      }
      let raf;
      function loop() { t++; draw(); if (!reduce) raf = requestAnimationFrame(loop); }
      canvas.addEventListener("pointerdown", (e) => { drag = { x: e.clientX, y: e.clientY, ox, oy }; canvas.setPointerCapture(e.pointerId); });
      canvas.addEventListener("pointermove", (e) => {
        if (drag) { ox = drag.ox + (e.clientX - drag.x) / scale; oy = drag.oy + (e.clientY - drag.y) / scale; if (reduce) draw(); return; }
        const rect = canvas.getBoundingClientRect();
        const mx = e.clientX - rect.left, my = e.clientY - rect.top;
        const pts = nodes.map(toScreen);
        let hit = -1, best = 18;
        pts.forEach((p, i) => { const dd = Math.hypot(p[0] - mx, p[1] - my); if (dd < best) { best = dd; hit = i; } });
        if (hit >= 0) { tip.style.opacity = "1"; tip.style.left = (mx + 12) + "px"; tip.style.top = (my + 12) + "px"; tip.textContent = nodes[hit].m.title; }
        else tip.style.opacity = "0";
      });
      window.addEventListener("pointerup", () => (drag = null));
      canvas.addEventListener("wheel", (e) => { e.preventDefault(); scale = Math.max(0.5, Math.min(3, scale * (e.deltaY < 0 ? 1.1 : 0.9))); if (reduce) draw(); }, { passive: false });
      resize(); loop();
      return () => { if (raf) cancelAnimationFrame(raf); };
    },
  };
  function legend(c, label) { return '<span class="const-legend__item"><span class="tier__gem" style="--tier-c:' + c + '"></span>' + E(label) + "</span>"; }

  /* ======================================================================
     SHARED PENSIEVE (teams) — forward-looking, gated
     ====================================================================== */
  const teams = {
    title: "Shared Pensieve",
    render() {
      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Shared Pensieve · coming", "A basin a team can share — without pooling secrets.",
            "The information architecture is built for it already: a shared workspace memory with per-member scopes and role-based visibility. " +
            "Each member’s strands stay sealed under their own key; the shared layer is what they choose to surface.") +
          '<div class="coming">' +
            '<span class="coming__tag">' + icon("teams") + " On the roadmap</span>" +
            '<h2 style="margin:16px 0 8px">Roles slot in without a redesign</h2>' +
            '<div class="grid grid--3" style="margin-top:24px;text-align:left">' +
              roleCard("Owner", "Sets workspace scopes, manages members, holds the workspace recovery path.") +
              roleCard("Contributor", "Commits to shared lanes; private strands stay sealed to them.") +
              roleCard("Reader", "Recalls shared memory; never sees another member’s private vault.") +
            "</div>" +
            '<p class="small dim" style="margin-top:24px">Built on the same registry + tokens + escrow model as your personal vault — org memory is an extension, not a rewrite.</p>' +
          "</div>" +
        "</div>"
      );
    },
  };
  function roleCard(name, body) {
    return '<div class="panel stack-2"><div class="row"><span class="domain__icon" style="--tier-c:var(--color-mercury-core)">' + icon("person") + "</span><h3>" + E(name) + "</h3></div><p class='small muted'>" + E(body) + "</p></div>";
  }

  /* ======================================================================
     RECALL ANALYTICS (forward-looking)
     ====================================================================== */
  const analytics = {
    title: "Recall Analytics",
    render() {
      const a = P.ANALYTICS;
      const max = a.mostRecalled[0].n;
      const bars = a.mostRecalled.map((x) => {
        const m = P.memById(x.id);
        return (
          '<div class="bar-row"><span class="bar-row__label">' + E(m.title) + "</span>" +
            '<span class="bar-row__track"><span class="bar-row__fill" style="width:' + Math.round((x.n / max) * 100) + '%"></span></span>' +
            '<span class="bar-row__v">' + x.n + "</span></div>"
        );
      }).join("");
      const mixTotal = a.sourceMix.reduce((s, x) => s + x.n, 0);
      const mix = a.sourceMix.map((x) =>
        '<div class="bar-row"><span class="bar-row__label">' + E(P.KIND_LABEL[x.kind]) + "</span>" +
          '<span class="bar-row__track"><span class="bar-row__fill" style="width:' + Math.round((x.n / mixTotal) * 100) + '%;--bar-c:' + x.color + '"></span></span>' +
          '<span class="bar-row__v">' + x.n + "</span></div>"
      ).join("");
      const stale = a.neverUsed.map((id) => window.C.strand(P.memById(id))).join("");

      return (
        '<div class="surface__inner stack-6">' +
          window.C.surfaceHero("Recall analytics · beta", "What your memory actually earns its keep doing.",
            "Most-recalled strands, source mix, and the memories gathering dust — so you can prune drift and keep the pool dense with signal.") +
          '<div class="grid grid--2">' +
            '<div class="panel stack-4">' + window.C.sectionHead("Most recalled", "last 30 days") + '<div class="bars">' + bars + "</div></div>" +
            '<div class="panel stack-4">' + window.C.sectionHead("Source mix") + '<div class="bars">' + mix + "</div>" +
              '<hr class="rule"/><div class="grid grid--3">' +
                window.C.stat("0.91", "recall precision", {}) + window.C.stat("38ms", "median recall", {}) + window.C.stat("2", "drifted", {}) +
              "</div></div>" +
          "</div>" +
          '<div class="panel stack-4">' + window.C.sectionHead("Memories you never use", "candidates to forget") +
            '<div class="stack-3">' + stale + "</div></div>" +
        "</div>"
      );
    },
  };

  window.SURFACES = {
    basin, recall, library, memory, remember, cloak, privacy, audit, vault, engine, settings,
    constellation, teams, analytics,
  };
})();
