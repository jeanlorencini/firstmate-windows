#!/usr/bin/env node
// Semantic policy for the subagent guard's shell-command seatbelt: does a shell
// command start a model agent harness CLI directly from the primary session?
//
// A primary that runs `codex exec ...`, `claude -p ...`, or another harness CLI
// outside bin/fm-brief.sh + bin/fm-spawn.sh creates work with no fleet record.
// This policy blocks that class of command text; primary-home scoping lives in
// bin/fm-subagent-pretool-check.sh. See docs/subagent-guard.md.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only. A command-text check is a
// seatbelt: indirection such as a script file or a variable-built command can
// still evade it.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "agent-cli-launch":
    "a shell command that starts a model agent harness CLI directly is blocked in the primary home; that path creates no durable fleet record and leaves firstmate guards inert. Classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work, passing --scout to both for a scout.",
};

// Harness CLI basenames bin/fm-harness.sh recognizes, plus Windows .exe forms
// stripped below. muse-bin-* is matched by prefix because the live process name
// carries a version suffix.
const HARNESS_CLIS = new Set([
  "claude",
  "codex",
  "opencode",
  "pi",
  "pi-signed",
  "grok",
  "kimi",
  "cursor-agent",
  "gemini",
  "muse",
  "rovo",
  "omp",
  "agy",
  "devin",
]);

// Non-launching queries and account/status surfaces. A harness CLI whose every
// argument is one of these (or that begins with one of these subcommands) is
// allowed; every other harness CLI invocation is treated as a launch.
const QUERY_FLAGS = new Set([
  "--version",
  "-v",
  "-V",
  "--help",
  "-h",
  "version",
  "help",
]);

const QUERY_SUBCOMMANDS = new Set([
  "auth",
  "login",
  "logout",
  "status",
  "models",
  "doctor",
  "completion",
  "whoami",
  "account",
  "config",
  "mcp",
  "version",
  "help",
]);

function basename(value) {
  return value.split(/[/\\]/).filter(Boolean).at(-1) || value;
}

function stripExe(name) {
  return name.replace(/\.exe$/i, "");
}

function commandLeaf(value) {
  return stripExe(basename(value)).toLowerCase();
}

function isHarnessCli(leaf) {
  if (HARNESS_CLIS.has(leaf)) return true;
  return leaf.startsWith("muse-bin-");
}

function isFmScript(leaf) {
  return leaf === "fm" || /^fm-[a-z0-9][-a-z0-9]*(\.sh)?$/.test(leaf);
}

function isQueryFlag(arg) {
  if (QUERY_FLAGS.has(arg)) return true;
  return /^--(help|version)(=|$)/.test(arg);
}

function isQueryOnly(args) {
  if (args.length === 0) return false;
  // Help/version short-circuit before a launch even after a launch-shaped
  // subcommand: `codex exec --help` and `opencode run --help` must stay allowed.
  if (args.some((arg) => isQueryFlag(arg))) return true;
  const first = args[0];
  if (QUERY_SUBCOMMANDS.has(first.toLowerCase())) return true;
  return false;
}

function deny(code, detail) {
  const reason = detail ? `${REASONS[code]} (cli: ${detail})` : REASONS[code];
  return { decision: "deny", code, reason, cli: detail || "" };
}

function shellCommandPayload(position) {
  if (!position.command) return null;
  const name = commandLeaf(position.command.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(words[i].value)) {
      let payloadIndex = i + 1;
      if (words[payloadIndex]?.value === "--") payloadIndex += 1;
      const payload = words[payloadIndex];
      if (!payload || !payload.literal || payload.subs.length > 0) return null;
      return payload.value;
    }
  }
  return null;
}

function literalEvalPayload(position) {
  if (!position.command || commandLeaf(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) {
    return null;
  }
  return payloads.map((payload) => payload.value).join(" ");
}

function classifyPosition(position) {
  if (!position.command) return null;
  const leaf = commandLeaf(position.command.value);
  if (isFmScript(leaf)) return null;
  if (!isHarnessCli(leaf)) return null;
  const args = position.words.slice(position.index + 1).map((word) => word.value);
  if (isQueryOnly(args)) return null;
  return deny("agent-cli-launch", leaf);
}

function analyze(command, depth = 0) {
  if (depth > 12) return { decision: "allow" };
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this seatbelt cannot tokenize. Deliberate obfuscation
  // and indirection stay out of scope by design (docs/subagent-guard.md).
  if (lexed.error) return { decision: "allow" };

  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);

    for (const token of tokens) {
      if (token.type !== "group") continue;
      const nested = analyze(token.content, depth + 1);
      if (nested.decision === "deny") return nested;
    }

    const shellPayload = shellCommandPayload(position);
    if (shellPayload) {
      const nested = analyze(shellPayload, depth + 1);
      if (nested.decision === "deny") return nested;
    }

    const evalPayload = literalEvalPayload(position);
    if (evalPayload) {
      const nested = analyze(evalPayload, depth + 1);
      if (nested.decision === "deny") return nested;
    }

    const hit = classifyPosition(position);
    if (hit) return hit;
  }
  return { decision: "allow" };
}

function decision(command) {
  return analyze(command, 0);
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
