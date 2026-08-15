#!/usr/bin/env node
//
// roadmap-stream-parse.js
//
// Incremental bridge between `claude -p --input-format stream-json
// --output-format stream-json` and the plain-text marker protocol
// run-roadmap.sh already speaks (grep for "${MARKER}_COMPLETE" etc. as a
// literal line in the transcript). Run once per poll tick by run-roadmap.sh
// against the growing raw output file of one streaming turn.
//
// Why this exists instead of a shell one-liner: stream-json output packs
// each assistant message onto a single JSON line with real newlines escaped
// as literal "\n" -- grepping that raw file directly for a marker works
// (the marker text survives JSON escaping unchanged), but `grep -oE
// "MARKER.*"` then captures to the end of that JSON line, i.e. the rest of
// the JSON envelope (usage stats, closing braces, ...) glued onto the
// marker text. run-roadmap.sh's existing extraction logic (PARTIAL/FAILED/
// REVIEW_ISSUES detail text, sliced with `sed`) needs real line breaks back.
// This script reconstructs a plain-text transcript (one real newline per
// assistant text block) so that existing logic keeps working unmodified.
//
// It is also why a naive raw-text quota-error grep is unsafe post-streaming:
// every turn's output now contains a benign `"type":"rate_limit_event"`
// telemetry line whose *type name* itself matches a loose
// /rate.?limit/ pattern. Quota detection must only ever look at
// reconstructed assistant text (or stderr), never the raw JSON -- see
// is_quota_error's comment in run-roadmap.sh.
//
// Usage:
//   node roadmap-stream-parse.js <raw_jsonl_file> <state_json_file> <text_out_file> <meta_out_file>
//
// Incremental: reads only the bytes appended since the last call (tracked in
// state_json_file, which also survives a run-roadmap.sh restart so resuming
// a turn never re-parses gigabytes of transcript from byte 0). Any trailing
// partial line (the writer hasn't flushed a full line yet) is left unread
// for the next call, never guessed at.
//
// Outputs:
//   text_out_file -- appended to (not rewritten) with one line per assistant
//                    text block seen, in order, with a real trailing
//                    newline restored. This is what run-roadmap.sh greps for
//                    the done/fail markers.
//   meta_out_file -- rewritten each call with simple KEY=VALUE lines (safe
//                    to `source` from bash, no JSON parsing needed there):
//                      RESULT_COUNT=<n>            total "result" events seen so far
//                      LAST_IS_ERROR=true|false    from the most recent result event
//                      LAST_SUBTYPE=<string>       e.g. success, error_max_turns, ...
//                      LAST_API_ERROR_STATUS=<n>   HTTP-style status if present, else empty
//                      LAST_RESULT_TEXT_LINES=<n>  how many text lines this call appended
//                      SESSION_COST_USD=<n>        sum of total_cost_usd across every
//                                                   result event this session has produced
//                                                   so far (a session may cover several
//                                                   result events -- nudges, live /pivot
//                                                   replies -- each with its own cost)
//                      LAST_TERMINAL_REASON=<str>  the most recent result event's
//                                                   terminal_reason (e.g. "completed"),
//                                                   used to fail fast on a per-turn
//                                                   --max-budget-usd cap instead of
//                                                   blindly retrying into the same wall
//
"use strict";
const fs = require("fs");

const [, , rawFile, stateFile, textOutFile, metaOutFile] = process.argv;
if (!rawFile || !stateFile || !textOutFile || !metaOutFile) {
  process.stderr.write(
    "usage: roadmap-stream-parse.js <raw_jsonl_file> <state_json_file> <text_out_file> <meta_out_file>\n",
  );
  process.exit(2);
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch {
    return {
      offset: 0,
      resultCount: 0,
      lastIsError: null,
      lastSubtype: "",
      lastApiErrorStatus: "",
      lastTerminalReason: "",
      cumulativeCostUsd: 0,
    };
  }
}

function safeKV(s) {
  // Values we emit are always booleans/numbers/short enum-like strings from
  // our own control, but strip anything that would break a bash `source`
  // of this file regardless, defensively.
  return String(s)
    .replace(/[\r\n]/g, " ")
    .replace(/[^\w.-]/g, "_");
}

let state = loadState();

let raw;
let stat;
try {
  stat = fs.statSync(rawFile);
  raw = fs.openSync(rawFile, "r");
} catch {
  // Output file doesn't exist yet (turn just started, writer hasn't
  // flushed anything). Nothing new to parse.
  writeMeta(state, 0);
  process.exit(0);
}

if (stat.size < state.offset) {
  // File is shorter than our last recorded offset -- a fresh turn reusing
  // the same scratch path. Start over rather than seeking past EOF.
  state.offset = 0;
}

const toRead = stat.size - state.offset;
let newTextLines = 0;
if (toRead > 0) {
  const buf = Buffer.alloc(toRead);
  fs.readSync(raw, buf, 0, toRead, state.offset);
  fs.closeSync(raw);
  const chunk = buf.toString("utf8");

  const lastNewline = chunk.lastIndexOf("\n");
  if (lastNewline === -1) {
    // No complete line yet in the new bytes -- wait for more.
    writeMeta(state, 0);
    process.exit(0);
  }
  const complete = chunk.slice(0, lastNewline + 1);
  state.offset += Buffer.byteLength(complete, "utf8");

  const textAppends = [];
  for (const line of complete.split("\n")) {
    if (!line.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue; // partial/corrupt line, ignore
    }

    if (obj.type === "assistant" && obj.message && Array.isArray(obj.message.content)) {
      for (const block of obj.message.content) {
        if (
          block &&
          block.type === "text" &&
          typeof block.text === "string" &&
          block.text.length > 0
        ) {
          textAppends.push(block.text);
        }
      }
    } else if (obj.type === "result") {
      state.resultCount = (state.resultCount || 0) + 1;
      state.lastIsError = !!obj.is_error;
      state.lastSubtype = obj.subtype || "";
      state.lastApiErrorStatus =
        obj.api_error_status === null || obj.api_error_status === undefined
          ? ""
          : obj.api_error_status;
      state.lastTerminalReason = obj.terminal_reason || "";
      if (typeof obj.total_cost_usd === "number" && Number.isFinite(obj.total_cost_usd)) {
        state.cumulativeCostUsd = (state.cumulativeCostUsd || 0) + obj.total_cost_usd;
      }
      // If this result is an error and the turn produced no assistant
      // text at all (e.g. a transport-level failure before any
      // response), surface *something* greppable so is_quota_error and
      // the generic failure path still have text to match against.
      if (
        obj.is_error &&
        textAppends.length === 0 &&
        typeof obj.result === "string" &&
        obj.result.length > 0
      ) {
        textAppends.push(`SYSTEM_ERROR[${obj.subtype || "unknown"}]: ${obj.result}`);
      } else if (obj.is_error && textAppends.length === 0) {
        textAppends.push(`SYSTEM_ERROR[${obj.subtype || "unknown"}]`);
      }
    }
  }

  if (textAppends.length > 0) {
    fs.appendFileSync(textOutFile, textAppends.join("\n") + "\n");
    newTextLines = textAppends.length;
  }
} else {
  fs.closeSync(raw);
}

fs.writeFileSync(stateFile, JSON.stringify(state));
writeMeta(state, newTextLines);

function writeMeta(s, newLines) {
  const lines = [
    `RESULT_COUNT=${safeKV(s.resultCount || 0)}`,
    `LAST_IS_ERROR=${s.lastIsError === null || s.lastIsError === undefined ? "unknown" : safeKV(s.lastIsError)}`,
    `LAST_SUBTYPE=${safeKV(s.lastSubtype || "")}`,
    `LAST_API_ERROR_STATUS=${safeKV(s.lastApiErrorStatus === undefined || s.lastApiErrorStatus === null ? "" : s.lastApiErrorStatus)}`,
    `LAST_RESULT_TEXT_LINES=${safeKV(newLines)}`,
    `SESSION_COST_USD=${safeKV((s.cumulativeCostUsd || 0).toFixed(6))}`,
    `LAST_TERMINAL_REASON=${safeKV(s.lastTerminalReason || "")}`,
    "",
  ];
  fs.writeFileSync(metaOutFile, lines.join("\n"));
}
