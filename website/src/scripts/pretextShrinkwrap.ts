// chenglou/pretext-powered text shrinkwrap layout engine.
// Relocated verbatim from a BaseLayout.astro `<script type="module">` (see
// emberSwarm.ts for the delivery rationale). The https://esm.sh import is kept
// as-is and marked rollup-external in astro.config.mjs: the marketing CSP
// (script-src 'self' + hashes) blocks esm.sh, so this module stays the same
// silent no-op it has always been in production. Bundling the npm package
// instead would ACTIVATE the shrinkwrap and change rendered text layout —
// that is a separate, visible-change decision, not a delivery optimization.
// @ts-nocheck — verbatim JS; strict-TS conversion deferred.
import { prepareWithSegments, layoutWithLines } from "https://esm.sh/@chenglou/pretext";

async function initPretextShrinkwrap() {
  try {
    await document.fonts.ready;
  } catch (e) {
    console.warn("Font loading check skipped:", e);
  }

  // Query all key copy elements for tight word wrapping
  const elements = document.querySelectorAll(
    ".pretext-wrap, .glass-wrap-text, .hero__h, .hero__copy .lead, .hero__attest > span, .trust__head h2, .trust__head .lead, .trust__quote blockquote p, .endcta__h, .endcta__inner h2, .endcta__inner p, .endcta__inner .lead, .pagehead__inner h1, .pagehead__inner p, .pagehead__inner .lead, .pagehead__lead"
  );

  // Styling reconstructor to restore semantic styling highlights on wrapped lines
  function reconstructLineHTML(lineText) {
    let html = lineText.trim();

    const highlights = [
      {
        phrase: "Before the bill.",
        replace: '<span class="hero__h-second">Before the bill.</span>'
      },
      {
        phrase: "local-first developer tool",
        replace: "<strong>local-first developer tool</strong>"
      },
      {
        phrase: "Every token leaves a trail. BurnBar reads the fire.",
        replace: "<em>Every token leaves a trail. BurnBar reads the fire.</em>"
      },
      { phrase: "Keep building.", replace: '<span class="ember">Keep building.</span>' },
      {
        phrase: "● No telemetry by default",
        replace: '<span class="ember">●</span> No telemetry by default'
      },
      {
        phrase: "● No account required",
        replace: '<span class="ember">●</span> No account required'
      },
      {
        phrase: "● Reads logs, not your API keys",
        replace: '<span class="ember">●</span> Reads logs, not your API keys'
      }
    ];

    for (const item of highlights) {
      if (html.includes(item.phrase)) {
        html = html.replace(item.phrase, item.replace);
      }
    }
    return html;
  }

  // Parse the element's child nodes into distinct blocks (e.g. separate standard text, second-row headings, br, etc.)
  function parseOriginalBlocks(el) {
    const blocks = [];
    let currentText = "";

    el.childNodes.forEach((node) => {
      if (node.nodeType === Node.ELEMENT_NODE) {
        const isSecond =
          node.className &&
          (node.className.includes("-second") ||
            node.classList.contains("hero__h-second") ||
            node.classList.contains("pagehead__h-second"));
        const isBr = node.nodeName === "BR";

        if (isBr || isSecond) {
          if (currentText.trim()) {
            blocks.push({ text: currentText.trim().replace(/\s+/g, " "), className: "" });
            currentText = "";
          }
          if (isBr) {
            blocks.push({ isBr: true });
          } else {
            blocks.push({
              text: node.textContent.trim().replace(/\s+/g, " "),
              className: node.className
            });
          }
        } else {
          // Sibling inline nodes (strong, em, spans) - extract text content to preserve
          currentText += " " + node.textContent;
        }
      } else if (node.nodeType === Node.TEXT_NODE) {
        currentText += " " + node.textContent;
      }
    });

    if (currentText.trim()) {
      blocks.push({ text: currentText.trim().replace(/\s+/g, " "), className: "" });
    }

    return blocks;
  }

  function relayout() {
    elements.forEach((el) => {
      // Retrieve or parse the cached blocks array to maintain consistency
      let blocks = el.__pretextBlocks;
      if (!blocks) {
        blocks = parseOriginalBlocks(el);
        el.__pretextBlocks = blocks;
      }

      // Cache original max-width on first pass before overriding it
      if (el.__pretextMaxWidth === undefined) {
        const originalMaxWidth = window.getComputedStyle(el).maxWidth;
        if (originalMaxWidth && originalMaxWidth !== "none") {
          el.__pretextMaxWidth = parseFloat(originalMaxWidth) || null;
        } else {
          el.__pretextMaxWidth = null;
        }
      }

      // Set parent styles to fit tight inline elements cleanly
      el.style.width = "100%";
      el.style.maxWidth = "none";
      el.style.background = "none";
      el.style.border = "none";
      el.style.boxShadow = "none";
      el.style.backdropFilter = "none";
      el.style.webkitBackdropFilter = "none";

      const style = window.getComputedStyle(el);
      const fontSize = parseFloat(style.fontSize);
      const fontFamily = style.fontFamily;
      const font = `${style.fontWeight || "400"} ${fontSize}px ${fontFamily}`;
      const lineHeight = parseFloat(style.lineHeight) || fontSize * 1.5;

      // Compute available parent width
      const parent = el.parentElement;
      if (!parent) return;

      // To prevent progressive shrink loops on "fit-content" glass wrappers,
      // measure the width of the stable block-level grandparent container instead.
      let measureContainer = parent;
      let parentWasFitContent = false;
      if (parent.classList.contains("lead-glass-wrap") || parent.classList.contains("glass-pane")) {
        measureContainer = parent.parentElement || parent;
        parentWasFitContent = true;
      }

      // Save original parent styles if it has fit-content
      let prevParentWidth = "";
      let prevParentMaxWidth = "";
      let prevParentDisplay = "";
      if (parentWasFitContent) {
        prevParentWidth = parent.style.width;
        prevParentMaxWidth = parent.style.maxWidth;
        prevParentDisplay = parent.style.display;

        // Force to full width block temporarily to get the natural grandparent width
        parent.style.width = "100%";
        parent.style.maxWidth = "none";
        parent.style.display = "block";
      }

      const parentWidth =
        measureContainer.clientWidth -
        parseFloat(window.getComputedStyle(measureContainer).paddingLeft) -
        parseFloat(window.getComputedStyle(measureContainer).paddingRight);

      // Restore parent styles immediately after measuring
      if (parentWasFitContent) {
        parent.style.width = prevParentWidth;
        parent.style.maxWidth = prevParentMaxWidth;
        parent.style.display = prevParentDisplay;
      }

      // Limit the maximum target wrapping width based on cached original max-width or sensible defaults for readability
      const maxConstraint =
        el.__pretextMaxWidth ||
        (el.classList.contains("lead") || el.classList.contains("pagehead__lead") ? 580 : 99999);

      // Apply a slight safety buffer so spans don't wrap prematurely
      const targetWidth = Math.max(160, Math.min(maxConstraint, parentWidth - 32));

      try {
        el.innerHTML = "";
        blocks.forEach((block, blockIndex) => {
          if (block.isBr) {
            el.appendChild(document.createElement("br"));
            return;
          }

          const segs = prepareWithSegments(block.text, font);
          const { lines } = layoutWithLines(segs, targetWidth, lineHeight);

          if (lines && lines.length > 0) {
            // If block has a specific class name (e.g. hero__h-second), create a container wrapper
            let container = el;
            if (block.className) {
              const wrapper = document.createElement("span");
              wrapper.className = block.className;
              el.appendChild(wrapper);
              container = wrapper;
            }

            lines.forEach((line, lineIndex) => {
              const span = document.createElement("span");
              span.className = "glass-line-pill";
              span.innerHTML = reconstructLineHTML(line.text);
              container.appendChild(span);

              if (lineIndex < lines.length - 1) {
                container.appendChild(document.createElement("br"));
              }
            });
          }

          // Add a newline between blocks if it's not the last block and not followed by a BR block
          if (blockIndex < blocks.length - 1 && !blocks[blockIndex + 1].isBr) {
            el.appendChild(document.createElement("br"));
          }
        });
      } catch (err) {
        console.debug("Pretext layout failed for element:", el, err);
      }
    });
  }

  // Run shrinkwrap layout
  relayout();

  // Listen for window resizes
  let resizeTimeout;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimeout);
    resizeTimeout = setTimeout(relayout, 100);
  });
}

// Initialize
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initPretextShrinkwrap);
} else {
  initPretextShrinkwrap();
}
