# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authoritative documents

- **[docs/PTAR_Rebaseline_Spec.md](docs/PTAR_Rebaseline_Spec.md)** — the specification. What the system must do.
- **[docs/Development_Protocol.txt](docs/Development_Protocol.txt)** — the process contract. How decisions get made and recorded while building it.

- **[docs/User_Story_Template.md](docs/User_Story_Template.md)** — how new work starts: the developer supplies a user story; Claude drives the requirements conversation (one question at a time, every item labeled Requirement / Assumption / Open, no solutions before acceptance criteria are approved) and records it in the decision log in four labeled blocks. Decisions, risk judgments and acceptance criteria stay the developer's.

- **[docs/lessons_learned.md](docs/lessons_learned.md)** — a running log of lessons from this project, kept for the release retrospective (after v1.0), where the developer triages each entry into Protocol, CLAUDE.md or noise. It is **not** the protocol. Append an entry (with its evidence) whenever a lesson appears; leave the Triage field blank.

The spec and the protocol govern every change made in this repo. Read them in full before a nontrivial behavioral change; the summaries below exist so the core rules are loaded every session without re-reading the full protocol each time, not as a replacement for it.

## What this is

PTAR (Project Triune AutoRoute) is a two-part Lua suite for **Project Triune / MacroQuest** (an EverQuest automation platform), not a standalone application. There is no build system, package manager, or linter — code is loaded and run live inside MacroQuest via `/lua run`. A local syntax check and unit-test suite exist for the MQ-free modules (see "Testing" below), but they only raise the floor: anything touching real MacroQuest/game behavior still needs a live-test pass before it can be called working.

Running it (for reference, not something you can do from here): `/lua run PTAR` (Runner) and `/lua run PTAR/PTAREditor` (Editor, normally launched from the Runner's "New / Edit Route" button, which spawns it as a separate Lua process).

## Source of truth

**[docs/PTAR_Rebaseline_Spec.md](docs/PTAR_Rebaseline_Spec.md)** is the authoritative specification — read it before making behavioral changes. It distinguishes confirmed facts, agreed requirements, open questions, and implementation choices (Section 4.1 explicitly calls out which timing/threshold constants are tunable implementation choices vs. fixed requirements). Section 21 lists concrete fixes agreed for the next version; Section 20 lists provisional/future items (route chaining, UI redesign) that are explicitly not yet designed.

## Development Protocol — core rules

Full text: [docs/Development_Protocol.txt](docs/Development_Protocol.txt). These are the rules that matter on every change; consult the full document for anything not covered here (e.g. Section 14's "what's OK to ask vs. resolve yourself" categories).

**Source of truth (§1).** The current spec document is authoritative. Never silently replace, reinterpret, or expand an agreed requirement because another approach seems easier, safer, or cleaner. Keep four categories distinct at all times and never promote one into another without saying so:
- *Confirmed fact* — established by source, docs, live testing, or logs.
- *Agreed requirement* — behavior explicitly approved.
- *Open question* — not yet determined.
- *Implementation choice* — left open by the spec, free to decide.

If new evidence contradicts the current design, stop and explain the conflict before changing the intended behavior.

**Decision log discipline (§2).** Maintain a running decision log of material design/behavior/architecture/scope/testing decisions as they're made — each entry states the decision, why, the evidence/requirement/constraint behind it, its status (confirmed/provisional/open-dependent), and what earlier decision it supersedes, if any. Never silently overwrite or reinterpret an earlier entry. If a decision supersedes a spec item, that supersession must be recorded visibly at the point the log is read (e.g. `SUPERSEDES spec §X.Y`), not left for someone to catch by diffing the log against the spec.

**Don't invent requirements (§3).** Don't add features, safety systems, recovery behavior, edge-case handling, configuration, or abstractions unless required to correctly implement agreed behavior, or explicitly requested/approved. Normal engineering completeness (resource cleanup, sensible error handling, usable UI, adequate diagnostics) is expected without asking — that's not the same as adding new product behavior. An observation or complaint is not automatically a change request.

**Resolve unknowns honestly (§4).** Don't guess at MacroQuest/Project Triune/TAC/external behavior — treat it as an open question until there's source or live evidence. Don't hide uncertainty behind an arbitrary timeout/retry/fallback presented as if the behavior were known.

**Build from behavior, not the last patch (§5).** Before changing a flow, reason through it fresh: what's supposed to happen, what proves each step occurred, what can fail or be ambiguous, what state transitions are possible, what a developer would need to diagnose a failure, and which behaviors are requirements vs. implementation choices. Don't just patch the most recently observed failure.

**One change at a time (§6).** Unless told otherwise, one substantive behavioral change per build: implement → dedicated diagnostic/instrumentation pass → review against the current spec → run available local/simulated tests → inspect that evidence as an outside developer would → only then hand off for live testing. Don't combine unrelated cleanup, refactors, or speculative fixes into the same build.

**Test requirements, not code paths (§7).** A passing test suite that only confirms current behavior isn't sufficient — every important requirement needs a test/review step that would fail if that requirement were violated. If an implementation choice changes while the requirement doesn't, the requirement-level test should still pass.

**Test-build diagnostics (§8).** Verbose diagnostic logging by default in test builds. Standard file layout: `macroquest\logs\<luaname>\`, `macroquest\config\<luaname>\`. A log must let another developer — without watching the live test — reconstruct build identity, state transitions, actions attempted, observations that drove decisions, retries and reasons, unexpected transitions, failures and causes, and the final outcome. If MacroQuest/an external component can't prove whether something succeeded, log that limitation explicitly rather than implying certainty. Inspect at least one representative log yourself before handoff.

**Build identity (§9).** Every test build gets a unique filename; the window title carries the same build identity; logs identify the running build. Never reuse a filename for a materially different build. Versions follow SemVer.

**Handoff standard (§10).** Never call a build "ready," "validated," or "passed" beyond what the evidence actually shows — distinguish local/simulated validation, static/code review, and live in-game validation explicitly. Before handoff, check: does this still match the current agreed spec, and if the live test fails unexpectedly, will the diagnostics probably explain why without burning another rare test condition? If either answer is no, it's not ready.

**Timing-value evidence standard (§15).** Retry counts, timeouts, and stall thresholds are implementation choices, not requirements, unless the spec says otherwise for that value. Surviving testing without a known failure is evidence a value hasn't been disproven — not evidence it's correctly tuned; don't describe it as "confirmed" or "correct" on that basis. Before proposing a change to one: (1) identify the specific failure mechanism from log data (e.g. still descending / still short of radius / still mid-crossing when the timeout fired — "operation timed out" alone is not enough), (2) rule out other causes the same evidence could support (timer too short, unrelated stall, dropped input, an uncaught interrupt, a one-off anomaly), (3) bring the evidence for discussion before proposing a new value, (4) only after discussion, record old value, new value, and the justifying log evidence as a decision log entry. Never adjust "to be safe," and never adjust just because another project uses a different value for a similarly-named constant.

**Stop conditions (§12).** Stop incremental patching and re-baseline against the spec if: implemented behavior turns out to differ from what was agreed; it's unclear whether something is a requirement or an implementation choice; an earlier agreement had to be quoted back because it was misremembered; tests pass but live behavior keeps contradicting expectations; logs can't explain observed behavior; several consecutive builds are fixes for the previous fix; or the implementation has become more complicated than the problem warrants.

## Architecture

### Module layout (`lua/PTAR/`)

- **PTAR.lua** (top-level, `lua/PTAR.lua`) — Runner entry point/UI. Builds the MacroQuest `adapter` (all `mq.TLO`/`mq.cmd` calls live here, wrapped in `pcall`), owns the ImGui draw loop and the route-selector/Start/Pause/Resume/Stop controls, and drives `runner:tick(now)` on a ~100ms loop.
- **PTARRunnerCore.lua** — the state machine (`M.new(route, io, opts)`). Pure logic, no MQ dependency — takes an injected `io` adapter so it can be reasoned about/tested independently of MacroQuest. Implements the 13-phase state machine (nav, backtrack, combat, door, door_zone, traverse_facing, traverse_approach, traverse_falling, water_facing, water_descend, water_cross, water_ascend, ground_exit) and the 8 statuses (Ready, Running, Recovering, Waiting for combat, Paused, Error, Manual handoff, Completed) described in spec Section 16.
- **PTARRouteData.lua** — route file schema (`FORMAT_VERSION = 3`), a hand-rolled literal-only parser/validator (`literal_only`) that rejects any executable Lua construct in a route file even when hand-edited, and atomic save (`.tmp` write → round-trip verify → promote → `.bak` retained).
- **PTARFiles.lua** — the route index (`PTAR_Routes.txt`), filename validation/sanitization, scanning/listing available routes, atomic index add.
- **PTARPaths.lua** — resolves the `PTAR` config/log subfolders under the MacroQuest config/logs roots (creating them if needed). The one-time legacy-file relocation behavior (from an earlier config-root layout) has been removed (DL-005); this module now only resolves and creates directories.
- **PTARCombat.lua** — reads combat/XTarget signals from `mq.TLO.Me`, isolated so the "am I in combat" decision logic can be reasoned about separately from the rest of the adapter.
- **PTARLog.lua** — file logger (`PTAR_<server>_<character>.log`), size-based rotation to `.old`. Every line is stamped with the running build's version. File logging always writes both EVENT and DEBUG levels unconditionally (no toggle reduces it); a separate `echo` flag controls only whether DEBUG lines are also mirrored to the in-game MQ console via an injected `echo_fn`, keeping this module MQ-free.
- **PTARVersion.lua** — the single authoritative version string (`VERSION`) and `is_test()` (derived from a `-test.` pre-release segment), required by `PTAR.lua`, `PTAREditor.lua`, and `PTARLog.lua` so the version can't drift between window titles and log lines.
- **PTARSettings.lua** — per-server/character runtime preferences (last-used route, MQ-console-echo preference, multi-box door role), plain `key=value` text with the same atomic tmp/bak/promote save pattern as `PTARFiles.lua`'s route index. Runner-only; the Editor doesn't read or write it.
- **PTAREditor.lua** — the separate Editor process/UI for capturing routes waypoint-by-waypoint at the character's live position. Capture-only by design: never moves the character, clicks doors, targets, or fights.

### Key design invariants (do not casually violate)

- **Editor is capture-only.** It reads live position/state to record waypoints but never issues movement, door-click, targeting, or combat commands.
- **Runner's state machine (`PTARRunnerCore.lua`) has no MQ dependency.** All actual game interaction is confined to the `adapter` table built in `PTAR.lua`. When changing runner behavior, keep this separation — don't reach into `mq.TLO`/`mq.cmd` from the state machine.
- **Route files are pure data.** `PTARRouteData.lua`'s literal-only parser is a deliberate security/robustness boundary; don't relax it to allow executable content.
- **Traversal waypoints (ground drop / water drop / water crossing) exist only because a segment has no navmesh coverage.** They use manual forward/vertical movement and speed/wetness-based phase detection — this manual-movement path is intentionally never used as a generic no-navmesh fallback for normal waypoints. A stalled traversal fails the leg outright rather than falling back to `/nav`.
- **Retries are scoped to normal-waypoint nav legs only** (2 retries in place, then 1 backtrack, then terminal failure). Every other wait in the system is a bounded timeout, not a retry — keep that distinction when touching timing logic.
- **`/face` heading and `Me.Heading.Degrees()` use opposite numeric conventions** on this game version; always go through `M.face_heading()` in `PTARRunnerCore.lua` when converting between them.
- **Saves are atomic everywhere** (route data, route index): write `.tmp`, verify, promote over the main file, retain `.bak`. Preserve this pattern in any code that persists files.
- **Start/Resume must be blocked during any active traversal phase** (spec Section 8/16, listed as a confirmed gap/required fix — check current code state before assuming it's already implemented).
- **Multi-character door coordination is scoped to `continue`/`finish_open` doors only.** `finish_zone` doors are untouched — every character always clicks its own zoning door and waits for its own zone transition, since zoning can't happen by proxy. Only the `continue`/`finish_open` shared branch checks `io.door_role()`/`io.door_confirmed()`; a `secondary` never clicks a door of that kind, under any circumstance, including its own timeout (see DL-008 — a fallback click there would reintroduce the exact multi-instance race it exists to prevent).

## Testing (DL-011 / DL-012)

Windows-only, run from the repo root with `luajit` (same runtime family as MacroQuest, LuaJIT 2.1) on PATH:

- `test\check.cmd` — syntax check, then the full test run. Exit code 0 only if both pass.
- `luajit test/harness/syntax_check.lua` — parse-checks every `.lua` under `lua/` and `test/` (exit 30 = syntax error, 31 = listing failed).
- `luajit test/harness/run.lua` — runs every `test/*_test.lua` in its own subprocess (exit 0 pass, 20 a file failed/crashed, 21 discovery/guard failure).

Layout: tests live in `test/` (never under `lua/`, which ships); every `.lua` directly in `test/` must be named `*_test.lua`; support code goes in `test/harness/`, vendored Lester in `test/vendor/`. `PTAR.lua` and `PTAREditor.lua` are parse-checked only. Tests use the real modules with fakes only at existing seams (RunnerCore's `io` adapter via `test/harness/sim.lua`, temp dirs for file modules).

Rules (full text in DL-012):
- Every test names the requirement it comes from (spec line, DL entry, or a real log line). Expected values come from that source, never from running the code and pasting the result. No source, no assertion.
- New or changed behavior: write the test from the requirement first, show it failing for the right reason, then implement. Regression tests on existing behavior must be proven able to fail by breaking the production condition.
- Assert observable behavior (status, phase, message, calls made through `io`) — not private fields, call counts, or source text.
- If a test fails, decide explicitly whether the code or the test is wrong. Changing an existing expected value is a spec-level change and needs developer sign-off.
- No test-only branches, flags, or hooks in `lua/`.
- A green run is never "verified": keep the local / code-review / live tiers distinct in handoffs. Tests never justify a timing constant (Protocol §15).

## Config directory

`config/` and `logs/` mirror the MacroQuest folder layout this suite expects at runtime (`macroquest/config/<name>/`, `macroquest/logs/<name>/`) — the actual per-server route files (`PTAR_*.lua`), the route index (`PTAR_Routes.txt`), and their `.bak`/`.tmp` counterparts live there. These are runtime/user data, not build artifacts.
