# Lessons Learned (running log)

Kept so nothing depends on either of our memories. **This is not the Development Protocol and does not change it.** At the release retrospective (after a stable v1.0) each entry is triaged by the developer into: **Protocol** (general project process), **CLAUDE.md** (working agreement with the AI, or project-specific guidance), or **Noise** (drop it).

How this log works:
- Claude appends an entry whenever a lesson appears during work, with the evidence that produced it (a decision-log entry, a commit, an incident).
- **Area** is what kind of lesson it is: Process, Collaboration, Technical or AI-behavior.
- **Suggested** is Claude's provisional guess at where it belongs. It is only a starting point for the retrospective.
- **Triage** stays blank until the retrospective. Do not fill it in earlier.
- Entries are append-only; a lesson found to be wrong is annotated, not deleted.

---

## 2026-09-28 (seeded from the first ~80 builds and the DL-010 / DL-011 to DL-013 work)

**L-001 — Build the test harness at the start, not after ~20 builds.**
Evidence: DL-011/DL-012 came late; earlier builds relied on live testing for logic bugs. Harness landed in `27926a6`.
Area: Process. Suggested: Protocol. Triage:

**L-002 — Prove tests can fail; isolate each mutation to one condition.**
Evidence: mutation checks caught weak tests (the `RouteData` identifier check "passed" for the wrong reason until a test was added; DL-013 steps 1–3). Two early mutations changed more than one line and muddied what they proved.
Area: Process. Suggested: Protocol. Triage:

**L-003 — Cite the requirement source for every expectation; never take expected values from the code's own output.**
Evidence: DL-012 guardrails; every `runner_core_test.lua` and `route_data_test.lua` test names its DL entry or spec line.
Area: Process. Suggested: Protocol. Triage:

**L-004 — Label Requirement / Design choices / Implementation choices / Open, and remember approval of a name or number does not make it a requirement.**
Evidence: DL-010 and DL-013 mixed the layers until the retrofit; Protocol §1 names four categories but the log blurred them.
Area: Process. Suggested: Protocol. Triage:

**L-005 — Start from a story and an observation, not a solution.**
Evidence: DL-013 began as a mechanism (explicit TAC commands) and the problem was written afterwards; no TAC interference had been observed. Led to `docs/User_Story_Template.md`.
Area: Process. Suggested: Protocol. Triage:

**L-006 — Track dependencies and shared seams between entries explicitly.**
Evidence: DL-010 and DL-013 both hook waypoint arrival and completion; the ordering (barrier, then `tac_before`, then the action) was only decided because the developer asked.
Area: Process. Suggested: Protocol. Triage:

**L-007 — Update status lines when the work lands, with commit hash and verification tier.**
Evidence: DL-011 and DL-012 kept saying "in progress" and "pending" after they shipped (fixed in `30ebb08`).
Area: Process. Suggested: Protocol. Triage:

**L-008 — Keep an explicit "unverified, do not describe as confirmed" list per entry.**
Evidence: DL-013's Unverified bullet (live status-line catch, `BeginDisabled` in PTAR, pause latency).
Area: Process. Suggested: Protocol. Triage:

**L-009 — Facts about the game, the developer's setup and risk tolerance must be asked, not inferred.**
Evidence: I treated a PT lockout as an unrecoverable cost without asking; the developer's facts (a manual waypoint before each door, Chase stalling at gaps, buffbots left at the entrance) each changed a recommendation.
Area: Collaboration. Suggested: Protocol (may overlap §14/§16) or CLAUDE.md. Triage:

**L-010 — Before agreeing a design, ask which parts are justified by an observation; record deferrals with a revisit trigger.**
Evidence: DL-010 grew (turn order, exclusion mark, re-send, GO) for problems nobody had seen; the scope-reduction review (DL-010 item 8) cut it back.
Area: Process. Suggested: Protocol. Triage:

**L-011 — Keep read-only local copies of external dependencies and cite file:line; a web-tool summary is a paraphrase, so check the raw text.**
Evidence: `reference/TAC` (v3.1) exposed Manual mode's default movement, the cast-time movement stop and the ungated plugin loop; the README summary alone would have missed them.
Area: Technical. Suggested: CLAUDE.md / project-specific. Triage:

**L-012 — Check the developer's sibling projects before designing a mechanism.**
Evidence: PTDeathRecovery already had the verified `/ac status` pattern; the DL-013 design took its shape instead of inventing one.
Area: Process. Suggested: CLAUDE.md. Triage:

**L-013 — Log every decision and every send with its reason; review a representative log as an outside developer.**
Evidence: the DL-013 retry log said "not confirmed" but not what had been sent; the diagnostic review found it and a send line was added.
Area: Process. Suggested: Protocol (§8 partly covers). Triage:

**L-014 — State when a step is not shippable alone; use one build number per live test; with manual folder-copy deployment, new files need a copy checklist.**
Evidence: DL-013 step 2 could not run in-game until the adapter existed; `PTARTac.lua` is a new file that must be copied with the tree.
Area: Process. Suggested: Protocol / CLAUDE.md. Triage:

**L-015 — Verify tooling assumptions by running them.**
Evidence: `cmd /c` strips outer quotes when a command has more than two (breaks paths with spaces; fixed by one outer pair, verified locally); `os.tmpname`, `xpcall`, exit-code and `popen:close()` assumptions were wrong when checked; long shell heredocs failed and were replaced by writing a file.
Area: Technical. Suggested: project-specific. Triage:

**L-016 — Append-only documents: retrofit by adding a classification section, never rewriting history; make status corrections visible.**
Evidence: the DL-010/DL-013 retrofit; DL-011/DL-012 status corrections noted in place.
Area: Process. Suggested: Protocol. Triage:

**L-017 — One question at a time, and no request for a decision while the discussion is still open.**
Evidence: I asked for the DL-010 barrier-timeout decision about four times while facts were still being gathered, and ended messages with lists of questions. Saved as a preference.
Area: Collaboration. Suggested: CLAUDE.md. Triage:

**L-018 — Give conclusions and constraints, not the full reasoning; say when a fact changes the recommendation.**
Evidence: the developer's "internal versus things you need to know" split; every fact that mattered was a constraint.
Area: Collaboration. Suggested: CLAUDE.md. Triage:

**L-019 — Bundled "agreed" is approval fatigue; approve item by item and label assumptions.**
Evidence: DL-013 recorded many implementation details as "decisions" through quick agreement on bundles.
Area: Collaboration. Suggested: CLAUDE.md / Protocol. Triage:

**L-020 — The developer's automation-versus-caution weighting is the developer's judgment; the AI states the worst case and recommends.**
Evidence: the barrier timeout and the unconfirmed-pause policy; the PT lockout correction removed my strongest objection.
Area: Collaboration. Suggested: CLAUDE.md. Triage:

**L-021 — AI memory-based claims need checking before they stand.**
Evidence: five were wrong when verified: `os.tmpname` paths, wrapping `xpcall`, a distinct launch exit code, `popen:close()` status, and MQ's Lua version.
Area: AI-behavior. Suggested: CLAUDE.md. Triage:

**L-022 — Ambiguous wording costs time; say who or what is meant.**
Evidence: "PTAR can't confirm a TAC command" was read as "nobody can"; the human could see TAC's acknowledgement line, PTAR could not read it.
Area: AI-behavior. Suggested: CLAUDE.md. Triage:

**L-023 — Welcome pushback in both directions.**
Evidence: the developer's corrections (doors, Chase, buffbots, "are we overengineering?") reshaped DL-010 and DL-013; the AI's challenge of the automation weighting and the fixed primary did the same.
Area: Collaboration. Suggested: CLAUDE.md. Triage:

**L-024 — Push docs-only changes without asking; ask before pushing code.**
Evidence: applied throughout; no friction.
Area: Collaboration. Suggested: CLAUDE.md. Triage:

**L-025 — Rebuild recaps from the repo and the log, not from memory; recaps expose stale entries.**
Evidence: the recap before DL-013 exposed the stale DL-011/DL-012 statuses.
Area: Process. Suggested: CLAUDE.md. Triage:

**L-026 — Read the existing code before extending it; it can hold a defect the design would have inherited.**
Evidence: reading `PTAR.lua` showed `confirmed_doors` is never cleared (across runs or zones), which changed DL-010's door-confirmation rule.
Area: Technical. Suggested: Protocol / CLAUDE.md. Triage:

**L-027 — Design a tool to be testable by separating its logic from its host bindings.**
Evidence: `PTARCombat` and `PTARTac` are MacroQuest-free modules, so the query guard and the combat decision are unit-tested; only the thin wiring is parse-checked.
Area: Technical. Suggested: CLAUDE.md. Triage:

**L-028 — A config mistake can look exactly like a code defect; per-client diagnostic logging is what tells them apart, not a plausible-sounding guess.**
Evidence: a DL-010 non-happy-path test (populated dungeon, combat, 2026-09-28) showed a door stuck closed for 8s despite a correct identity match (no DL-014-style Target mismatch), then opening cleanly on retry — a pattern that could easily have been misdiagnosed as a game-side click miss or a new code bug. Reading both clients' logs side by side showed the real cause: the developer had forgotten to set `door_role=secondary` on one character before the run, so both clients clicked the same door within 0.3s of each other; the log line `Door role set to secondary`, fired mid-run when the developer corrected it live, pinpointed the exact moment the symptom stopped. Without that log line and the side-by-side comparison, this would have been an unexplained one-off.
Area: Technical. Suggested: Protocol (reinforces §4/§15 — don't guess at a cause, check the evidence) or CLAUDE.md. Triage:
