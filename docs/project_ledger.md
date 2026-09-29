# PTAR Project Ledger

Maintained per [Development_Protocol.txt](Development_Protocol.txt) Section 11. This ledger tracks the project's *current state* in four categories. Read this first to orient; consult [decision_log.md](decision_log.md) for the rationale, history, and active overrides behind any entry only as needed — don't reconstruct current state by reading the full decision log from scratch.

When new evidence resolves an open question, update this ledger before building on that conclusion. Do not silently rewrite prior entries — if something here turns out wrong, record the correction and, if the correction is material, add a decision log entry explaining why.

## Up next

**[DL-014](decision_log.md#dl-014--door-identity-match-drops-z-some-doors-travel-far-in-z-when-opening-portcullis-style-gates) (door identity match drops Z) is now live-verified** at the door that found the problem (`0.2.0-test.26`, 2026-09-28) — see Resolved behavior below. **[DL-010](decision_log.md#dl-010--multi-client-waypoint-barrier-sync-agreed-design-implementation-deliberately-held) is now live-verified end to end**, including requirement #3 (twice, with two different non-PTAR grouped characters — Shia, then Benedict) and a non-happy-path run (populated dungeon, a pet class holding real sustained combat, 24/24 barrier releases matched on both characters). The `mq.TLO.Group.Member` self-exclusion assumption is resolved (direct diagnostic, 2026-09-28: confirmed the local character is never listed), and the chat-ordering assumption has been checked against the existing Kateri/Evelynne log (all 6 doors crossed, correct order every time, not contradicted). The primary-drops gap (item 5) is reclassified as intended v1.0 behavior, deferred to a post-1.0 feature release (developer decision, 2026-09-29) — not a release blocker. The barrier-timeout-then-proceed path is opportunistic-only, not a pending test. **DL-010 has no remaining release-blocking open items.** The "Door Role" UI label question is resolved: deferred to the separate pre-1.0 UI design pass, left as-is until then.

## Dependencies (not yet built)

Only unbuilt entries are listed; everything else is delivered. Reasoning and order rules live in the entries.

Everything below is now built; nothing remains in this section as of `0.2.0-test.25` (2026-09-28).

## Pending Live Verification

Implemented code changes not yet confirmed by live testing. Check this before assuming a fix in the code is validated — cross-reference each with its decision log entry for full context. Move an item out of this section (and update its decision log status) the moment it's confirmed, whichever bucket it's in.

**Opportunistic only** — can't be deliberately engineered, will be confirmed whenever the right conditions occur naturally during ordinary play:
- ~~DL-007~~ — **live-verified 2026-09-28, moved to Resolved behavior below.**
- ~~DL-006's `ground_exit` combat-pause-and-resume~~ — **not opportunistic; developer accepted the unit-test + shared-code-path evidence instead of a dedicated live test, 2026-09-28. See the DL-006 entry.**
- [DL-010](decision_log.md#dl-010--multi-client-waypoint-barrier-sync-agreed-design-implementation-deliberately-held)'s barrier-timeout-then-proceed path — no combat pause has come close to the 120000 ms ceiling yet; developer decision, 2026-09-29, not worth a dedicated live test, confirmed whenever it naturally occurs.

**Partially live-verified, new finding, 2026-09-28:**
- [DL-006](decision_log.md#dl-006--ignore-combat-during-traversal-phases-treat-ground_exit-combat-like-normal-nav) — Decision 1 (ignore, don't instant-fail) is **live-verified PASS**. The `water_ascend` stall finding now has a **second data point in its favor**: a follow-up run with TAC paused for the whole traversal chain (see DL-013 below) saw combat overlap the span on both characters with no stall — consistent with, though not proof of, the hypothesis that TAC's Manual-mode movement was the cause. Decision 2 (`ground_exit`'s combat-pause-and-resume) is accepted on unit-test + shared-code-path evidence, not live-tested — see the entry.

**Live-verified, 2026-09-28** — build `0.2.0-test.23`:
- [DL-013](decision_log.md#dl-013--route-authored-tac-pauserun-events-explicit-opt-in-verified-through-ac-status) (route-authored TAC pause/run events) — the core mechanism is confirmed: PTAR's `mq.event` catches TAC's status line live, pause/run both confirmed on attempt 1 on two characters, the whole three-drop chain (including the navmeshed hallways) stayed paused correctly, and `finish_backtrack`'s check-first logic was exercised live as a bonus. The UI graying mechanism itself is now live-confirmed too (via DL-001's shared fix, below) — not yet observed during a TAC phase specifically, but it's the identical code path. **Editor combo layout confirmed too (retroactively, 2026-09-29)** — the live-test route file itself has `tac_before="pause"` on `wp_060` and `tac_after="run"` on `wp_062`, which could only have gotten there through the Editor's combos. DL-013 has no remaining untested paths.

- ~~DL-010's core barrier mechanism and requirement #3~~ — **live-verified 2026-09-28, moved to Resolved behavior below.** `Group.Member` self-exclusion, the chat-ordering assumption, and the non-happy-path (populated dungeon, combat) test have since all been completed/checked (2026-09-28/29) — see Resolved behavior. Item 5 (primary-drops gap) reclassified as intended v1.0 behavior, not a pending item.

- ~~DL-014~~ — **live-verified 2026-09-28, moved to Resolved behavior below.**

- ~~DL-001's diagnostic edge case~~ — **live-verified PASS, 2026-09-28** (`PTAR_multiclass_Erebeth.log`, `21:38:26.464`).
- ~~DL-001's follow-up usability fix~~ (block message was overwritten within seconds by routine narration; fixed with a live-recomputed `traversal_blocking()` query and UI graying, `v0.2.0-test.24`) — **live-verified PASS, 2026-09-28**, screenshot + developer confirmation: the yellow explanation line stayed visible through ongoing traversal progress, and Start/Use Nearest/Resume all rendered visibly dimmed together while Pause/Stop stayed normal. DL-001 has no remaining untested paths.

## Resolved behavior

Behavior actually agreed upon (source: [PTAR_Rebaseline_Spec.md](PTAR_Rebaseline_Spec.md), approved as current source of truth).

- Two-part suite: Editor (capture-only, never moves/clicks/targets/fights) and Runner (playback via MQ2Nav plus special-case handling for ground drops, water drops, water crossings, doors).
- Route files are pure data behind a literal-only parser; route schema changes are never auto-applied, and an unsupported `format_version` is hard-rejected, never silently edited or upgraded.
- Saves (route data and route index) are atomic: `.tmp` write, round-trip verify, promote to main, `.bak` retained.
- Normal nav legs: 2 retries in place, then 1 (non-retried) backtrack to the last known-good waypoint, then terminal failure. This is the only true retry-covered operation in the system; every other wait (14+ across nav/drops/water/doors/combat) is a bounded wait, not a retry.
- No navmesh / no path available fails the leg immediately via the same retry/backtrack/fail sequence as a stall — no generic manual-movement fallback for normal waypoints.
- Traversal capture order: departure position+heading → ledge (if a fall phase exists) → underwater target (requires FeetWet=true and HeadWet=true) → exit (requires FeetWet=false for any water-phase preset).
- Ground drop: fails outright (not "short") if total descent doesn't meet the minimum threshold.
- Water drop/crossing: landing requires FeetWet=true or the leg fails outright; completion requires FeetWet=false and being within the exit's radius.
- Door outcomes are distinct: continue / finish_open / finish_zone, each with its own wait-then-click-or-click-then-wait sequencing; a normal door falls back to advancing on an unconfirmed state (logged as a stall fallback), a finish_zone door fails the leg outright on the same condition.
- Pause is unguarded at every phase, by design — it only stops movement and never attempts further navigation afterward, so it's mechanically safe even mid-traversal.
- Resume searches for the nearest reachable waypoint (bounded elevation range, valid path) rather than resuming the exact interrupted step — deliberately different from DeathRecovery's model, because PTAR's terrain has navmesh gaps by definition and DeathRecovery's environment (The Bazaar) does not.
- Terminal statuses (Error, Completed, Manual handoff, Ready) are distinct and not interchangeable; there is no auto-rearm after Completed/Manual handoff, matching PTAR's always-user-initiated trigger model (vs. DeathRecovery's async death trigger).
- File logging is always full verbose/DEBUG in every build, with no toggle to reduce it.
- No user-configurable retry/timeout settings — deliberate, given the size/interdependence of the timing surface and the lack of live-test data justifying specific values.
- Route selector / Refresh Routes are guarded against Running/Recovering/Waiting-for-combat (would swap route data out from under an active run); Start/Pause/Resume/Stop are not guarded against active status, since they only command state and never replace route data — except that Start/Resume now additionally refuse to act while `self.phase` is any of the 7 traverse/water_* phases, per DL-001 (**live-verified, PASS**, 2026-09-27).
- Editor and Runner are independent processes with no cross-process awareness; the Runner only reloads route data on an explicit, already-guarded user action, so editing/saving in the Editor while the Runner is active does not corrupt or desync anything.
- Log/config folder separation (`macroquest/config/<name>` vs `macroquest/logs/<name>`) is confirmed correct and will be the standard pattern adopted across other projects. The folder itself is now named `PTAR` (renamed from the legacy `PTAutorunner`, [DL-004](decision_log.md#dl-004--rename-the-ptautorunner-folder)).
- File relocation-on-launch (moving legacy route/log files from the raw MacroQuest config root) has been **removed** ([DL-005](decision_log.md#dl-005--remove-routelog-file-relocation-on-launch-behavior-before-release)) — `PTARPaths.lua` now only resolves/creates the `PTAR` config and log directories, nothing more.
- **[DL-001](decision_log.md#dl-001--block-startresume-during-any-active-traversal-phase)** (Start/Resume traversal-phase guard): implemented, **live-verified PASS**, 2026-09-27. Diagnostic edge case and a follow-up UI-persistence fix (block message no longer gets overwritten by routine narration, `v0.2.0-test.24`) both **live-verified PASS, 2026-09-28**.
- **[DL-006](decision_log.md#dl-006--ignore-combat-during-traversal-phases-treat-ground_exit-combat-like-normal-nav)** (ignore combat during traversal, pause-and-resume for `ground_exit`): implemented. Ignore-combat decision **live-verified PASS, 2026-09-28**; `ground_exit`'s pause-and-resume accepted without a live test (see above). Corrects spec §4.
- **[DL-007](decision_log.md#dl-007--fall-approach-passed-limit-failure-the-2d-distance-formula-not-the-capture-is-wrong)** (ground-drop approach limit: 3D distance, `+45` margin): implemented, **live-verified PASS, 2026-09-28** — two independent characters through the incident waypoint `wp_060`, both clean.
- **[DL-002](decision_log.md#dl-002--mq-console-echo-toggle-per-line-version-stamping-single-authoritative-version-source)/[DL-003](decision_log.md#dl-003--persist-last-used-route-and-mq-console-echo-preference-per-servercharacter)** (version source, MQ-console echo, persisted settings): implemented, **live-verified PASS**, 2026-09-27. Shipped as `v0.2.0-test.20`.
- **[DL-004](decision_log.md#dl-004--rename-the-ptautorunner-folder)/[DL-005](decision_log.md#dl-005--remove-routelog-file-relocation-on-launch-behavior-before-release)** (folder rename to `PTAR`, relocation-on-launch removed): implemented, **live-verified PASS**, 2026-09-27. Shipped as `v0.2.0-test.21`. All five of Section 21's original fixes now implemented and verified.
- **[DL-008](decision_log.md#dl-008--multi-character-door-coordination-via-group-chat-primarysecondary-roles)** (multi-character door coordination via group chat): implemented, **live-verified PASS**, 2026-09-27. Shipped as `v0.2.0-test.22`.
- **[DL-014](decision_log.md#dl-014--door-identity-match-drops-z-some-doors-travel-far-in-z-when-opening-portcullis-style-gates)** (door identity match drops Z, for portcullis-style gates that travel in Z when opening): implemented, **live-verified PASS**, 2026-09-28, at door #44 (Sleeper's Tomb, the door that found the problem) — clean `open=true` confirmation through the door's full Z travel, zero `Target mismatch` lines, Primary announced correctly. Shipped as `v0.2.0-test.26`.
- **[DL-010](decision_log.md#dl-010--multi-client-waypoint-barrier-sync-agreed-design-implementation-deliberately-held)** (multi-client waypoint barrier sync): implemented, **live-verified PASS**, 2026-09-28 — core mechanism confirmed across three separate test runs, including a non-happy-path run with a pet class holding real sustained combat in a populated dungeon (24/24 clean releases on both characters, zero timeouts, correct combat-pause-and-resume at every barrier); requirement #3 (a group member not running PTAR must never hold a barrier) confirmed live twice, with two different non-PTAR grouped characters (Shia, then Benedict), neither ever appearing in an `expected` list. `Group.Member` self-exclusion confirmed live via a direct diagnostic (2026-09-28: local character never listed); the chat-ordering assumption checked against the existing log (6/6 doors correct order, not contradicted, 2026-09-29). Item 5 (primary-drops gap) is reclassified as intended v1.0 behavior, deferred to a post-1.0 feature release (developer decision, 2026-09-29) — not a release blocker. The barrier-timeout-then-proceed path is opportunistic-only, not a pending test. Shipped as `v0.2.0-test.25`.

## Confirmed live/system facts

Facts established through source inspection, documentation, or (once it occurs) live testing.

- Route `format_version = 3`. Waypoint types: normal, door, traverse, finish.
- Traversal presets: ground (`{fall}`), water_drop (`{fall, descend, cross, ascend}`), water_cross (`{descend, cross, ascend}`).
- Traversal departure/approach radius defaults to 3 if left blank; capped at 5 maximum.
- Underwater target radius has no fallback default (required for water_drop/water_cross only) — swimming drift from interacting variables (momentum, heading, etc.) is too fast-changing to generalize a default for.
- Exit radius is required on every traverse preset including ground, with no code-level fallback (Editor UI pre-fills 5 as a suggestion only).
- Ground drop detection is speed-based: descent >15 Z/s signals a fall has begun; landing is declared once vertical speed stays under 4 Z/s for 750ms; minimum 15 Z units total descent required.
- Normal nav legs: 2 retries in place, then 1 backtrack, then terminal failure (see also Resolved behavior).
- Combat interrupts navigation, door interaction, and `ground_exit` legs; 2000ms clear-and-resume delay after combat ends. **The 7 traverse/water phases do not get this treatment** — combat is ignored during them instead ([DL-006](decision_log.md#dl-006--ignore-combat-during-traversal-phases-treat-ground_exit-combat-like-normal-nav), corrects spec §4).
- `/face` and `Me.Heading.Degrees()` use opposite numeric directions on RoF2 (source comment + explicit conversion function, `PTARRunnerCore.face_heading`).
- Implementation state machine has 13 phases and 8 statuses (spec §16) — see [CLAUDE.md](../CLAUDE.md) architecture section for the current list.
- Section 4.1 timing/threshold constants are implementation choices, not derived requirements. **One has been attributed to a live failure and revised** ([DL-007](decision_log.md#dl-007--fall-approach-passed-limit-failure-the-2d-distance-formula-not-the-capture-is-wrong)). The rest remain unproven-not-wrong, not confirmed-correct, per Development Protocol §15.
- The config/log subfolder is now named `PTAR` (see [PTARPaths.lua](../lua/PTAR/PTARPaths.lua)), renamed from the legacy `PTAutorunner` per DL-004.

## Open implementation details

Questions intentionally unresolved — do not decide these unilaterally; surface them for discussion when they become relevant.

- **Route ending rule, provisional (spec §5):** the current rule that a route must have an explicit ending (finish waypoint, manual handoff, or finish-configured door) before it can be loaded/run is accurate to today's code but flagged provisional — a future route-chaining feature may require it to change. Also currently adds testing friction (no end-to-end run during capture without planting/removing a Finish waypoint each time).
- **Persistence-to-root, provisional (spec §13):** once route trees exist, last-used-route persistence should resolve to the root of the tree rather than the specific sub-route last active. Depends on the not-yet-designed route-chaining feature.
- **Door/door_zone phase safety for Start/Resume interruption (spec §8, §16):** assumed safe because a door position is proven reachable by ordinary route playback before door logic ever runs — but this is an assumption, not yet independently live-verified. Treated as self-resolving through ordinary use rather than requiring dedicated testing; only revisit if a specific failure is observed and logged.
- **Route chaining design (spec §20):** a Finish that loads a different route (e.g. Eastern Wastes → Sleeper's Tomb) is not yet designed. Affects the route-ending rule (§5) and the persistence-to-root caveat (§13) above. Do not implement any part of this speculatively.
- **Full UI redesign, both Runner and Editor windows (spec §11, §20):** current layout for both windows is not considered satisfactory; a redesign is planned as a future revision and is explicitly out of scope for the current spec document.
- **TAC integration, if ever added (spec §3, §15):** out of scope for this version; if added later, scope is explicitly limited to starting TAC in Manual mode when the user presses Start — no broader TAC state management. Not a current open question, but noted so a broader TAC integration is never assumed in without a fresh scoping discussion.
- **[DL-009](decision_log.md#dl-009--levitate-breaks-ground-drop-traversal-fall-detection-known-limitation-deferred)** — Levitate breaks ground-drop fall-detection: confirmed, deliberately deferred as a known limitation (don't levitate before a fall-based traversal).
- **[DL-010](decision_log.md#dl-010--multi-client-waypoint-barrier-sync-agreed-design-implementation-deliberately-held)** — multi-client waypoint barrier sync (solves the DL-008-discovered drift/combat-desync problem): design fully agreed, built as `0.2.0-test.25`, **live-verified end to end, 2026-09-28** (see Resolved behavior above). Scope reduced after an over-engineering review (built the core barrier + active-only heartbeat + proceed-on-timeout; traversal-departure choreography and other extras deferred until live logs justify them). No remaining release-blocking open items: the primary-drops gap (item 5) is intended v1.0 behavior, deferred to a post-1.0 feature release (2026-09-29); the chat-ordering assumption is checked, not contradicted; the barrier-timeout path is opportunistic-only. "Door Role" relabel deferred to the pre-1.0 UI design pass.

## Out of scope

Explicitly decided not to build or investigate (spec §15).

- Navmesh generation, installation, or repair.
- Broader TAC control beyond starting it in Manual mode on Start (see Open implementation details above for the narrow exception).
- Death detection/recovery — an intentional tool separation from DeathRecovery, not a missing integration. PTAR has no death awareness. May be reconsidered later; no current plans.
- Combat participation — PTAR only detects combat to pause/resume navigation, never fights.
- Automatic route generation/pathing discovery — routes are always hand-captured.
- Cross-zone routes — a route is locked to a single `zone_short_name`.
