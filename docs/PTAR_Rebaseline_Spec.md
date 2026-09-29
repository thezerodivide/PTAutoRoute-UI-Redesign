# PTAR — Rebaseline Specification

*Reverse-engineered from source, then reviewed section by section and resolved through discussion. Reflects agreed requirements as of this review, including items scoped for a future version.*

## Document header

| | |
|---|---|
| **Document status** | Reviewed and resolved section-by-section — approved as current source of truth |
| **Implementation status** | Existing, working Lua suite; 5 concrete fixes identified for next version (see Section 21) |
| **Source of truth** | This document after review/approval |

---

## 1. Purpose

PTAR (Project Triune AutoRoute) is a two-part Lua suite for Project Triune / MacroQuest:

- An Editor (PTAREditor.lua) that captures a route through a dungeon, waypoint by waypoint, at the character's live position.
- A Runner (PTAR.lua) that plays a saved route back: normal navigation via MQ2Nav between waypoints, with special-case handling for ground drops, water drops, water crossings, and doors.

> **Design boundary:** PTAR automates the boring travel and combat-adjacent interactions required to reach a boss encounter the user actually cares about. It is explicitly not designed as a replacement for TAC, MQ2Nav, or any other existing tool — it orchestrates them for a specific narrow purpose, rather than reimplementing or superseding what they already do.

## 2. Design Principles

- Route files are pure data — a literal-only parser rejects any executable content, even in a hand-edited file.
- The Editor never moves the character, clicks doors, targets, fights, or calls TAC — capture-only, by design.
- Manual movement (forward/vertical) is scoped only to captured traversal phases, never used as a generic no-navmesh fallback.
- Retries are scoped per named operation; bounded waits are handled separately from retries.
- Saves are atomic: .tmp write, round-trip verify, promote to main, .bak retained.
- Route file schema changes are never auto-applied. A route on an unsupported format_version is hard-rejected, never silently edited or upgraded. Backwards compatibility is not a concern before v1.0 — schema is expected to change as functionality grows, and auto-migration risk isn't worth taking on this early.

## 3. Prerequisites and Operating Assumptions

- MacroQuest running with Lua, ImGui, and MQ2Nav available.
- A loaded navmesh for the target zone (PTAR checks for one; does not install or generate one).
- For door waypoints: the target door is reachable via /doortarget id \<id\> or Select Nearest Door.

> **Boundary:** PTAR does not create/generate navmeshes, does not configure MQ2Nav, and — for this version — does not manage TAC. If TAC integration is added in a future version, scope is explicitly limited to starting TAC in Manual mode when the user presses Start; nothing broader.

> **File relocation:** Route and log files are automatically relocated from the MacroQuest config root into a dedicated subfolder on every launch, if legacy files are found there. This relocation-only behavior (never a schema edit) stays active during testing and is scheduled for removal before release.

## 4. Confirmed PTAR / MacroQuest Facts

- Route format_version = 3. Waypoint types: normal, door, traverse, finish.
- Traversal presets: ground (phases = {fall}), water_drop (phases = {fall, descend, cross, ascend}), water_cross (phases = {descend, cross, ascend}).
- Traversal departure/approach radius defaults to 3 if left blank; capped at 5 maximum.
- Underwater target radius: required for water_drop/water_cross only (not applicable to ground). No fallback default, by design — the underwater target is reached via automated swimming subject to drift from multiple interacting variables (momentum, heading, etc.) that change too quickly to isolate or generalize, so the radius must be set deliberately per traversal.
- Exit radius: required on every traverse preset, including ground. No code-level fallback, though the Editor UI pre-fills the input field with 5 by default.
- Capture order for a traversal: departure position+heading -> ledge (if a fall phase exists) -> underwater target (requires FeetWet=true and HeadWet=true) -> exit (requires FeetWet=false for any water-phase preset).
- /face and Me.Heading.Degrees() use opposite numeric directions on RoF2 (explicit source comment + conversion function).
- Ground drop detection is speed-based: descent >15 Z/s signals a fall has begun; landing is declared once vertical speed stays under 4 Z/s for 750ms. Minimum 15 Z units total descent required or the leg fails.
- Normal nav legs: 2 retries in place, then 1 backtrack attempt to the last known-good waypoint, then terminal failure.
- Combat interrupts navigation, door interaction, and any traverse phase; 2000ms clear-and-resume delay after combat ends.
- Door handling distinguishes continue / finish_open / finish_zone outcomes, each with its own wait-then-click-or-click-then-wait sequencing.
- A ground-drop or water-traversal waypoint exists specifically because no navmesh covers that segment — that is the entire reason the waypoint type exists. A stalled traversal fails the leg outright rather than falling back to /nav, because /nav was never a viable option for that segment in the first place.

### 4.1 Implementation choices, not data-driven

> **Standard for revisiting these:** These timing/threshold constants (fall windows, water descend/cross/exit timeouts, heading tolerances, stall/timeout thresholds throughout Sections 6, 7, and 9) were implementation choices made during prior development, not derived from a stated requirement. Live testing to date has not surfaced a failure attributable to any specific value, but that is evidence of "no known problem," not evidence of correct tuning. They remain implementation choices, free to change without a requirements conflict. A value is only reconsidered based on logged evidence of the specific failure mechanism observed — never on a bare timeout with no supporting detail.

## 5. Route Capture Lifecycle (Editor)

- A route is created fresh (name + zone + description) or loaded/recovered from existing files (main -> .tmp -> .bak, in that priority).
- Capture is blocked outright if current zone does not match the route's stored zone.
- Every completed capture auto-saves immediately — no unsaved-draft state for individual waypoints.
- A traversal capture is a multi-click, in-memory-only session until the final exit click, at which point the whole waypoint is created and saved atomically; Cancel Traversal Capture discards it without touching the route.

> **Provisional, not settled:** The current rule that a route must have an explicit ending (finish waypoint, manual-handoff, or finish-configured door) before it can be loaded/run is accurate to today's code, but is flagged provisional. A future route-chaining feature (a Finish that loads a different route, e.g. Eastern Wastes -> Sleeper's Tomb) may require this rule to change. It also currently adds testing friction, since a route can't be run end-to-end during capture without planting and removing a Finish waypoint each time. Not resolved — parked pending the route-chaining design.

## 6. Route Playback Workflow (Runner)

For a normal (non-traverse, non-door) waypoint:

- If already within the waypoint's radius, treat as reached immediately.
- Otherwise confirm a navmesh is loaded and a path exists, then issue /nav and monitor progress.
- Stall/failure conditions (implementation-choice timing values, see 4.1): no progress toward the waypoint for a bounded window, OR total time exceeds a bounded cap, OR /nav reports inactive after a short grace period without reaching the radius.
- On leg failure: retry in place (up to 2), then attempt one backtrack to the last known-good waypoint, then terminal failure.

> **No navmesh / no path available:** The leg fails immediately via the same retry/backtrack/fail sequence as a stall, rather than triggering any generic manual-movement fallback. Manual movement is only ever used inside a route's own captured traverse waypoints.

## 7. Special Navigation Cases: Traversals and Doors

Traversal waypoints exist specifically to cover navmesh gaps — that is their entire reason for existing. Every phase of every traversal, by definition, occurs in a location with no navmesh coverage.

### 7.1 Ground drop

- Face the captured departure heading; verify before moving (tolerance is an implementation choice, see 4.1).
- Walk forward; monitor descent speed to detect fall start and landing (thresholds are implementation choices, see 4.1).
- Total descent must meet a minimum threshold or the drop is considered failed, not merely short (see 4.1).
- After landing, navigate from the landing point to the captured exit if not already within its radius.

### 7.2 Water drop (fall then swim)

- Same fall/landing detection as a ground drop; landing must show FeetWet=true or the leg fails outright.
- Face the captured underwater target; descend until both FeetWet and HeadWet are true and near the captured depth.
- Cross underwater toward the target, correcting depth/heading periodically, until within the target's radius.
- Ascend toward the captured dry exit; completion requires FeetWet=false and being within the exit's radius.

### 7.3 Water crossing (no fall)

- Same descend/cross/ascend sequence as 7.2, without the fall/landing phase.

### 7.4 Doors

- continue: wait for closed state, click once, wait for open, then continue.
- finish_open: same as continue, but the route ends (manual mode) once the door reads open.
- finish_zone: click regardless of state, then wait for a zone change; route ends (manual mode) upon zoning.
- If a door's state cannot be confirmed within a short grace period: a normal door falls back to advancing anyway (logged as a stall fallback); a finish_zone door fails the leg outright.

## 8. Pause / Resume

- Pause halts navigation/movement immediately and clears the current waypoint index. Pause is unguarded and can be pressed at any time, in any phase, without restriction — this is intentional: pausing is the user's judgment call about their own character, and PTAR has no basis to second-guess it. It is also mechanically safe even mid-traversal, since Pause stops movement without attempting any further navigation afterward.

> **Resume behavior — resolved, intentional design:** Resume does not continue the exact interrupted step. It searches for the nearest reachable waypoint (within a bounded elevation range and a valid path) and resumes from there, which can mean skipping waypoints in either direction relative to where the pause occurred. This is intentional and differs from DeathRecovery's "resume the exact suspended step" model for a specific reason: DeathRecovery can safely resume the exact step because its environment (The Bazaar) is fully navmeshed, so no user movement during a pause can invalidate the resume target. PTAR cannot make that assumption — its terrain includes navmesh gaps by definition (that's why traversal waypoints exist), so a paused user could move somewhere the interrupted step no longer safely applies to. "Nearest reachable" is the only recovery option that doesn't presuppose the paused state is still valid. Pause/resume design should be justified against each project's specific environment guarantees, not assumed consistent across projects.

> **Start/Resume traversal guard — confirmed gap, fix required next version:** Start and Resume must be blocked whenever the runner's current phase is any traversal phase (traverse_facing, traverse_approach, traverse_falling, water_facing, water_descend, water_cross, water_ascend) — not only mid-fall/mid-swim, since every traversal phase occurs in a navmesh gap by definition. Without this guard, Start/Resume will halt movement and then attempt to navigate to an unreachable point, producing an immediate, avoidable Error. This gap exists because traversal support was added after the original guardrails were designed, and the guardrails were never revisited against the new phase set. Door/door_zone phases are assumed safe from this same concern — a door position is proven reachable by ordinary route playback before door logic ever runs, so no separate guard or verification campaign is needed there. This is an assumption, not yet independently live-verified, but it self-resolves through ordinary use rather than requiring dedicated testing.

## 9. Retry and Timeout Semantics

- Only one true retry-covered operation exists: normal waypoint navigation legs (2 retries, then 1 backtrack, then terminal failure). The backtrack itself is a single bounded-wait attempt, not retried.
- Every other wait in the system (14+ distinct bounded waits across nav, drops, water traversal, doors, and combat recovery) is a bounded wait, not a retry — governed separately per the standing design principle that retries belong to named actions and timeouts belong to named waiting states.
- No runtime judgment is made about "realistic chance of success" — every failure path is a fixed count or fixed duration, never adaptive.

> **No user-configurable retry/timeout settings — intentional:** Unlike DeathRecovery, which exposes a single Retry Count, none of PTAR's retry/timeout values are user-adjustable. This is deliberate: PTAR's timing surface is large and interdependent, and exposing that much raw tuning detail would add complexity without benefit, especially since none of the specific values currently have live-test data justifying them as correct rather than merely unproven-wrong. Adjustments happen through code changes and decision log entries per the 4.1 standard, not a settings panel.

## 10. Failure and Success Handling

Terminal statuses are distinct and not interchangeable:

- **Error** — a leg/phase failed. Movement halted, waypoint index cleared. Requires explicit Resume (nearest valid) or Stop.
- **Completed** — reached a finish waypoint, a finish_open door, or zoned through a finish_zone door.
- **Manual handoff** — reached a waypoint explicitly flagged manual_handoff.
- **Ready** — reached only via explicit Stop; the only status that resets the start-waypoint selection back to the first waypoint.

> **No auto-rearm, and this is correct as-is:** PTAR has no DeathRecovery-style "return to Monitoring" behavior — after Completed or Manual handoff, the runner simply sits in that terminal status until the user acts. This is correct, not a gap: DeathRecovery needs an auto-rearm because its trigger (death) is an external, asynchronous event that can occur at any time while unsupervised. PTAR's trigger is always user-initiated (clicking Start), so there is nothing for it to wait for unsupervised. For the same reason, there is no separate persisted "Last result/error" field distinct from the live status message — nothing auto-resets, so nothing needs to be preserved across a reset that never happens.

## 11. User Interface

> **Known limitation, deferred:** The current UI layout, for both the Runner and Editor windows, is not considered satisfactory. A redesign is planned as a future revision and is explicitly out of scope for this document.

Runner window (PTAR.lua):

- Route selector, Refresh Routes, New/Edit Route (launches the Editor as a separate Lua process), console-echo toggle (see Section 12), notice text.
- Route selector and Refresh Routes are guarded against Running/Recovering/Waiting for combat, since they would swap the underlying route data out from under an active run.
- Start, Pause, Resume, Stop are not guarded against active status by design — they only command state, they never replace route data, so mid-run use is safe except for the traversal-phase case covered in Section 8.
- Status line, wrapped message text, Current waypoint, Start-waypoint selector.

Editor window (PTAREditor.lua):

- New/load/add-existing route, Action selector (Add Waypoint, Capture Door, Add Finish, three traverse presets, plus Insert Before/After variants), capture fields, full route order list with per-waypoint edit, inline validation.

> **Editor/Runner independence — confirmed safe, intentional:** The Editor and Runner are independent processes with no cross-process awareness; the Runner holds its own in-memory copy of a route once loaded. Editing and saving a route file in the Editor while the Runner is actively using it does not corrupt or silently desync anything, because the Runner only reloads on an explicit, already-guarded user action. This allows deliberately deferring a reload until edits are finished — not a risk, a supported working pattern.

## 12. Logging and Diagnostics

- File logging is always at full verbose/DEBUG level, in every build, with no toggle to reduce it — this replaces the current code's behavior of skipping DEBUG-level file writes when a Verbose toggle is off.

> **MQ-console echo — new feature, not present in current code:** A new, separate toggle controls only whether DEBUG-level lines are also echoed to the in-game MQ console; file logging is unaffected by its state either way. The toggle is always present in the UI, in every build type. Its default state differs by build: on by default in test builds, off by default in release/release-candidate builds. Once a user has set an explicit preference, the persisted value always wins over the build default on subsequent launches (see Section 13).

- Every log line must include the running build's version number. This depends on the single-authoritative-version-value fix in Section 14 — the two are one combined piece of work, not separable.

> **Diagnostic standard:** Inherited directly from Development Protocol Section 8: could another developer, who has never seen this project, read the log and determine what happened, why, when, and where the evidence ends? No PTAR-specific restatement needed.

> **Restored requirement:** Per-line version stamping was specifically requested previously and lost during an earlier implementation pass. This is a confirmed, concrete example of a stated requirement being silently dropped — the exact failure mode the Development Protocol's decision-log discipline exists to prevent.

## 13. Persistence and Session Behavior

- Last-used route persists across relaunches, per server/character.

> **Provisional caveat, linked to Section 5:** Once route trees exist (a Finish that loads a different route), persistence should resolve to the root of the tree rather than the specific sub-route last active, so relaunching mid-chain doesn't strand the user on a route that no longer makes sense in isolation. Depends on the same not-yet-designed chaining feature as Section 5's provisional ending-rule note.

- The MQ-console-echo toggle (Section 12) persists per server/character. The build-based default (on for test, off for release) applies only on first use, before any preference has been set; once set, the persisted value always wins over the build default.

## 14. Release Identity and Packaging

> **Confirmed fix required:** Version identity must be derived from a single authoritative internal value. Current code hardcodes the version string separately in each window's title (both currently read v0.2.0-test.18 as independent literals), creating drift risk. This is the same fix required for per-line log version stamping (Section 12) — one combined piece of work.

> **Folder naming — confirmed fix required:** The config/logs subfolder is currently named PTAutorunner, a legacy name. It should be renamed for consistency with the project's actual name before this structure becomes the template other projects copy.

- Log/config folder separation itself (macroquest/config/\<name\> vs macroquest/logs/\<name\>) is confirmed correct and matches Development Protocol Section 8. This structure is intentional and will be adopted as the standard across other projects going forward — only the specific folder name needs to change, not the separation pattern.

## 15. Out of Scope

- Navmesh generation, installation, or repair.

> **TAC control:** Out of scope for this version. If added in a future version, scope is explicitly narrow: limited to starting TAC in Manual mode when the user presses Start. No broader TAC state management.

> **Death detection/recovery:** Fully out of scope, and this is an intentional tool separation, not a missing integration. DeathRecovery's own job is to return the character to the start of the instance and restart TAC — it does not know about or restart a PTAR route. PTAR has no death awareness at all. May be reconsidered at a later date, but there are no current plans for integration.

- Combat participation — PTAR only detects combat to pause/resume navigation, never fights.
- Automatic route generation/pathing discovery — routes are always hand-captured.
- Cross-zone routes — a route is locked to a single zone_short_name.

## 16. Implementation State Machine

Phases (13, source-confirmed): nav, backtrack, combat, door, door_zone, traverse_facing, traverse_approach, traverse_falling, water_facing, water_descend, water_cross, water_ascend, ground_exit.

Statuses (8): Ready, Running, Recovering, Waiting for combat, Paused, Error, Manual handoff, Completed.

> **Guard requirement tied to Section 8:** Start and Resume must check the current phase (not just status) and refuse if phase is any of the seven traverse/water_* phases. This is a different check from the existing route-swap guard, which checks status. Pause remains fully unguarded and unaffected at every phase.

> **Assumption, pending live verification:** Door and door_zone phases are assumed safe for Start/Resume interruption at any point, since a door position is proven reachable by ordinary route playback (nav must reach it before door logic ever runs) — not a separate verification task, and self-confirming through ordinary use rather than requiring a dedicated test pass. This assumption stands unless a specific failure is observed and logged, following the same standard as Section 4.1: evidence of the actual failure mechanism, discussed, then decision-logged.

## 17. Confirmed Live Validation

> **Deliberately empty:** This section is not backfilled from prior conversation history, which is not considered a reliable source for this purpose. Entries are added going forward from this document's approval, as actual live testing occurs.

## 18. Development and Validation Guardrails

- This approved document is the source of truth. Do not silently reinterpret it.
- Distinguish confirmed fact, agreed requirement, open question, and implementation choice.
- If a new decision conflicts with an approved requirement, surface the existing requirement, explain why it needs review, and obtain approval before changing it.
- One behavior change at a time when practical, followed by a dedicated diagnostic/instrumentation pass before scarce live testing.
- Every test build uses a unique filename and matching visible build identity.
- Do not claim 'passed', 'validated', or 'ready' beyond the evidence actually obtained.

## 19. Review Checklist

- Does every requirement describe an observable outcome, necessary integration constraint, or explicit project boundary?
- Are any Section 4.1 implementation choices actually requirements that should be locked instead?
- Does the traversal/door special-case handling match intended behavior?
- Is anything in this codebase mischaracterized or missed?

## 20. Provisional and Future Items

Not yet designed; noted so neither is lost, and neither gets decided prematurely:

- Route chaining — a Finish that loads a different route (e.g. Eastern Wastes -> Sleeper's Tomb). Affects Section 5's ending rule and Section 13's persistence-to-root caveat.
- Full UI redesign for both Runner and Editor windows — explicitly deferred, out of scope for this document.

## 21. Concrete Fixes for Next Version

- Block Start/Resume during any active traversal phase (Sections 8, 16).
- MQ-console echo toggle (new) + per-line version stamping + single authoritative version source — one combined piece of work (Sections 12, 14).
- Persist last-used route and MQ-console-echo preference per server/character (Section 13).
- Rename the PTAutorunner folder to something consistent with the project name (Section 14).
- Route/log file relocation-on-launch behavior is intentional for now, but scheduled for removal before release (Section 3).
