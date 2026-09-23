#!/usr/bin/env node
//
// turn-usage.js -- part of ftero-scripts. Summarizes where one Claude Code
// session's tokens went: request count, output/cache totals, and the largest
// tool results that sat in its context. Point it at a transcript under
// ~/.claude/projects/<workspace-dir>/<session-id>.jsonl, e.g. the one whose
// modification time matches an expensive line in specs/.roadmap-cost:
//   node turn-usage.js ~/.claude/projects/<dir>/<session-id>.jsonl
//
const fs = require("fs");

const file = process.argv[2];
if (!file) {
  process.stderr.write("usage: turn-usage.js <session.jsonl>\n");
  process.exit(2);
}

const events = fs
  .readFileSync(file, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((l) => {
    try {
      return JSON.parse(l);
    } catch {
      return null;
    }
  })
  .filter(Boolean);

const totals = { requests: 0, output_tokens: 0, cache_read: 0, cache_write: 0, uncached_in: 0 };
const seen = new Set();
const results = [];
for (const e of events) {
  const m = e.message;
  if (e.type === "assistant" && m && m.usage && !seen.has(m.id)) {
    seen.add(m.id);
    totals.requests++;
    totals.output_tokens += m.usage.output_tokens || 0;
    totals.cache_read += m.usage.cache_read_input_tokens || 0;
    totals.cache_write += m.usage.cache_creation_input_tokens || 0;
    totals.uncached_in += m.usage.input_tokens || 0;
  }
  if (e.type === "user" && m && Array.isArray(m.content)) {
    for (const c of m.content) {
      if (c.type === "tool_result") {
        const text = JSON.stringify(c.content || "");
        results.push([text.length, text.slice(0, 100)]);
      }
    }
  }
}

console.log(totals);
console.log("largest tool results (chars, start):");
results.sort((a, b) => b[0] - a[0]);
for (const [len, start] of results.slice(0, 10)) console.log(len, start);
