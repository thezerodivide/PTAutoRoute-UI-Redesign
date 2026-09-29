-- Requirement tests for PTARRunnerCore. Each test names the decision-log entry (docs/decision_log.md) or spec
-- line its expectation comes from. The runner is driven only through its public API (start/resume/pause/stop/
-- tick) with a scripted fake io (test/harness/sim.lua); assertions are on status, phase, message and the calls
-- the runner made to the game.
local T = require 'harness.t'
local Sim = require 'harness.sim'
local test, expect = T.test, T.expect

local Core = require 'PTAR.PTARRunnerCore'

local TRAVERSAL_PHASES = { 'traverse_facing', 'traverse_approach', 'traverse_falling',
                           'water_facing', 'water_descend', 'water_cross', 'water_ascend' }

local function wp(id, x, y, z, extra)
  local w = { id = id, label = id, type = 'normal', x = x, y = y, z = z, heading = 90 }
  for k, v in pairs(extra or {}) do w[k] = v end
  return w
end

local function route(waypoints)
  return { format_version = 3, next_id = 100, route_name = 'R', zone_short_name = 'zone', description = '', waypoints = waypoints }
end

-- Water-drop traverse at the origin followed by a finish at its exit.
local function water_route()
  return route({
    wp('wp_001', 0, 0, 0, { type = 'traverse', radius = 3, phases = { 'fall', 'descend', 'cross', 'ascend' },
      ledge = { x = 0, y = -50, z = 0 }, underwater_target = { x = 0, y = -80, z = -60, radius = 4 },
      exit = { x = 0, y = -120, z = -40, radius = 5 } }),
    wp('wp_002', 0, -120, -40, { type = 'finish', radius = 5 }),
  })
end

-- Ground-drop traverse at the origin. By default the exit is far from the landing point, so a ground_exit leg is needed.
local function ground_route(exit, extra)
  local rt = route({
    wp('wp_001', 0, 0, 0, { type = 'traverse', radius = 3, phases = { 'fall' },
      ledge = { x = 0, y = -50, z = 0 }, exit = exit or { x = 0, y = -60, z = -40, radius = 5 } }),
    wp('wp_002', 0, -60, -40, { type = 'finish', radius = 5 }),
  })
  for k, v in pairs(extra or {}) do rt.waypoints[1][k] = v end
  return rt
end

local function far_route()
  return route({ wp('wp_001', 0, -200, 0, { radius = 5 }), wp('wp_002', 0, -400, 0, { type = 'finish', radius = 5 }) })
end

-- Drives the runner through legitimate ticks until it is in `target` ('landed' = just after the fall settles,
-- whatever phase that leads to). Returns runner, sim, and the current time.
local function to_phase(rt, target)
  local s = Sim.new()
  local r = Core.new(rt, s.io)
  local t = 1000
  local function tick(dt) t = t + (dt or 100); r:tick(t) end
  r:start(1, t)
  tick()                                          -- within radius of the traverse: begin_traverse
  if r.phase == target then return r, s, t end
  s.heading = 90; tick()                          -- heading verified: approach begins
  if r.phase == target then return r, s, t end
  s.p.z = -2; tick()                              -- 20 Z/s: fall starts
  if r.phase == target then return r, s, t end
  s.feet = true
  s.p.z = -30; tick()                             -- still dropping
  tick(); tick(400); tick(400)                    -- vertical speed ~0 for >= 750 ms: landing
  if r.phase == target or target == 'landed' then return r, s, t end
  s.heading = s.bearing; tick()                   -- water_facing -> water_descend
  if r.phase == target then return r, s, t end
  s.head, s.p.z = true, -60; tick()               -- deep enough: water_cross
  if r.phase == target then return r, s, t end
  s.p.y = -80; tick()                             -- at the underwater target: water_ascend
  if r.phase == target then return r, s, t end
  error('to_phase: could not reach ' .. target .. ' (stopped in ' .. tostring(r.phase) .. ')')
end

-- ================================================================ DL-001
for _, phase in ipairs(TRAVERSAL_PHASES) do
  test('DL-001: Start, Resume and Use-Nearest are blocked in phase ' .. phase .. ' and issue no game commands', function()
    local r, s, t = to_phase(water_route(), phase)
    expect.equal(r.phase, phase)
    local before = #s.calls
    local status_before = r.status
    r:start(1, t + 10)
    T.assert_contains(r.message, 'Start/Resume blocked')
    T.assert_contains(r.message, phase)
    r:resume(t + 20)
    T.assert_contains(r.message, 'Start/Resume blocked')
    r:start_nearest(t + 30)
    T.assert_contains(r.message, 'Start/Resume blocked')
    expect.equal(#s.calls, before)   -- no /nav, no stop, no key release: nothing was touched
    expect.equal(r.phase, phase)
    expect.equal(r.status, status_before)
  end)
end

test('DL-001: Use-Nearest during a traversal names the traversal block even when no other waypoint is reachable', function()
  local r, s, t = to_phase(water_route(), 'traverse_approach')
  s.path = false
  r:start_nearest(t + 10)
  T.assert_contains(r.message, 'Start/Resume blocked')
  expect.falsy(r.message:find('No reachable dry waypoint', 1, true))
end)

test('DL-001: Start is not over-blocked during ordinary navigation (pause, then start again works)', function()
  local s = Sim.new()
  local r = Core.new(far_route(), s.io)
  r:start(1, 1000)
  expect.equal(s.count('nav'), 1)
  r:pause()
  expect.equal(r.status, 'Paused')
  r:start(1, 2000)
  expect.equal(r.status, 'Running')
  expect.equal(s.count('nav'), 2)
  expect.falsy(r.message:find('blocked', 1, true))
end)

test('DL-001: Stop clears the guard, so Start works again after stopping mid-traversal', function()
  local r, s, t = to_phase(water_route(), 'traverse_approach')
  r:stop()
  expect.equal(r.status, 'Ready')
  s.p = { x = 0, y = 0, z = 0 }
  r:start(1, t + 100)
  expect.equal(r.status, 'Running')
  expect.falsy(r.message:find('blocked', 1, true))
end)

test('DL-001: a traverse that ends the route by manual handoff straight from landing does not leave Start blocked', function()
  -- Exit already within radius: landing goes directly to advance(), which must leave no stale traversal phase.
  local r, s, t = to_phase(ground_route({ x = 0, y = 0, z = -30, radius = 5 }, { manual_handoff = true }), 'landed')
  expect.equal(r.status, 'Manual handoff')
  local navs = s.count('nav')
  r:start(1, t + 100)
  expect.falsy(r.message:find('blocked', 1, true))
  expect.equal(r.status, 'Running')
  expect.equal(s.count('nav'), navs + 1)
end)

-- ================================================================ DL-006
for _, phase in ipairs(TRAVERSAL_PHASES) do
  test('DL-006: combat has no effect on the runner in phase ' .. phase, function()
    local function next_tick(combat)
      local r, s, t = to_phase(water_route(), phase)
      s.combat = combat
      r:tick(t + 100)
      return { status = r.status, phase = r.phase, message = r.message, calls = s.names() }
    end
    local with_combat, without = next_tick(true), next_tick(false)
    expect.equal(with_combat, without)   -- "runs exactly as if not in combat"
    expect.truthy(with_combat.phase ~= 'combat')
    expect.truthy(with_combat.status ~= 'Waiting for combat')
  end)
end

test('DL-006: combat during ground_exit pauses the leg (Waiting for combat) instead of failing', function()
  local r, s, t = to_phase(ground_route(), 'ground_exit')
  local stops = s.count('nav_stop')
  s.combat = true
  r:tick(t + 100)
  expect.equal(r.status, 'Waiting for combat')
  expect.equal(r.phase, 'combat')
  expect.truthy(s.count('nav_stop') > stops)
end)

test('DL-006: after combat clears, ground_exit resumes by re-issuing /nav to the captured EXIT, not the waypoint', function()
  local rt = ground_route()
  local r, s, t = to_phase(rt, 'ground_exit')
  s.combat = true
  r:tick(t + 100)
  s.combat = false
  local navs = s.count('nav')
  r:tick(t + 200)                       -- clear window starts
  expect.equal(r.phase, 'combat')
  expect.equal(s.count('nav'), navs)    -- not resumed immediately
  r:tick(t + 3000)                      -- well past the clear delay
  expect.equal(r.phase, 'ground_exit')
  expect.equal(s.count('nav'), navs + 1)
  expect.truthy(s.last('nav')[1] == rt.waypoints[1].exit)
end)

test('DL-006: ordinary nav combat still pauses and resumes toward the same waypoint (spec s4 unchanged)', function()
  local rt = far_route()
  local s = Sim.new()
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  s.combat = true
  r:tick(1100)
  expect.equal(r.status, 'Waiting for combat')
  s.combat = false
  local navs = s.count('nav')
  r:tick(1200)
  r:tick(4000)
  expect.equal(s.count('nav'), navs + 1)
  expect.truthy(s.last('nav')[1] == rt.waypoints[1])
end)

-- ================================================================ DL-007
-- Geometry is the real incident (DL-007): wp_060 departure and ledge, 3D distance ~103.2, so limit ~148.2.
local function approach_route()
  return route({
    wp('wp_060', 619.659, -2236.979, -444.873, { type = 'traverse', radius = 3, phases = { 'fall' },
      ledge = { x = 617.781, y = -2335.123, z = -412.873 }, exit = { x = 619, y = -2400, z = -450, radius = 5 } }),
    wp('wp_061', 619, -2400, -450, { type = 'finish', radius = 5 }),
  })
end

local function approach_after_walking(distance)
  local rt = approach_route()
  local s = Sim.new()
  s.p = { x = 619.659, y = -2236.979, z = -444.873 }
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  r:tick(1100)                    -- traverse_facing
  s.heading = 90
  r:tick(1200)                    -- traverse_approach; origin recorded here
  expect.equal(r.phase, 'traverse_approach')
  s.p.y = s.p.y - distance        -- walk straight ahead, level with the origin
  r:tick(1300)
  return r
end

for _, d in ipairs({ 113.6, 146 }) do
  test('DL-007: an approach of ' .. d .. ' units toward a ledge ~103.2 units away (3D) does not fail', function()
    local r = approach_after_walking(d)
    expect.equal(r.status, 'Running')
    expect.equal(r.phase, 'traverse_approach')
  end)
end

test('DL-007: an approach beyond ledge distance (3D) + 45 fails, naming the 148.2 limit', function()
  local r = approach_after_walking(150)
  expect.equal(r.status, 'Error')
  T.assert_contains(r.message, 'Fall approach passed 148.2-unit limit')
end)

-- ================================================================ DL-008
local function door_route(after)
  return route({
    wp('wp_001', 0, 0, 0, { type = 'door', door_after = after, door = { id = 77, name = 'door', x = 0, y = 0, z = 0 } }),
    wp('wp_002', 0, -100, 0, { type = 'finish', radius = 5 }),
  })
end

-- Runner standing at the door waypoint, in the door phase, with the given role.
local function at_door(role, after)
  local s = Sim.new()
  s.role = role
  local r = Core.new(door_route(after), s.io)
  r:start(1, 1000)
  r:tick(1100)
  expect.equal(r.phase, 'door')
  return r, s, 1100
end

local function advanced_to_next_waypoint(r, s)
  return r.index == 2 and s.last('nav') ~= nil and s.last('nav')[1].id == 'wp_002'
end

test('DL-008: a primary that sees the door open advances and announces it exactly once', function()
  local r, s, t = at_door('primary')
  s.door_state = true
  r:tick(t + 400)
  expect.truthy(advanced_to_next_waypoint(r, s))
  expect.equal(s.count('announce'), 1)
  expect.equal(s.last('announce')[1], 77)
end)

test('DL-008: a secondary that itself sees the door open advances without announcing', function()
  local r, s, t = at_door('secondary')
  s.door_state = true
  r:tick(t + 400)
  expect.truthy(advanced_to_next_waypoint(r, s))
  expect.equal(s.count('announce'), 0)
end)

test('DL-008: a secondary advances on a group-chat confirmation without ever clicking', function()
  local r, s, t = at_door('secondary')
  s.door_state = false
  s.confirmed[77] = true
  r:tick(t + 400)
  expect.truthy(advanced_to_next_waypoint(r, s))
  expect.equal(s.count('door'), 0)
end)

test('DL-008: a secondary never clicks, even after its own wait times out; the leg ends in Error', function()
  local r, s, t = at_door('secondary')
  s.door_state = false
  local now = t
  while now < t + 120000 and r.status ~= 'Error' do
    now = now + 300
    r:tick(now)
  end
  expect.equal(r.status, 'Error')       -- bounded: it gives up rather than waiting forever
  expect.equal(s.count('door'), 0)      -- and never clicked
end)

test('DL-008: a primary whose door state is unavailable proceeds but does NOT announce', function()
  local r, s, t = at_door('primary')
  s.door_state, s.door_detail = nil, 'unavailable'
  local now = t
  while now < t + 10000 and r.index ~= 2 do
    now = now + 300
    r:tick(now)
  end
  expect.truthy(advanced_to_next_waypoint(r, s))
  expect.equal(s.count('announce'), 0)
end)

test('DL-008: a primary facing a closed door clicks it, then advances and announces once it reads open', function()
  local r, s, t = at_door('primary')
  s.door_state = false
  r:tick(t + 400)
  expect.equal(s.count('door'), 1)
  expect.equal(s.last('door')[2], nil)  -- an ordinary click, not the forced zoning click
  expect.equal(r.index, 1)
  s.door_state = true
  r:tick(t + 800)
  expect.truthy(advanced_to_next_waypoint(r, s))
  expect.equal(s.count('announce'), 1)
end)

test('DL-008: finish_zone is untouched - a secondary still clicks its own zoning door', function()
  local r, s, t = at_door('secondary', 'finish_zone')
  s.door_state = false
  r:tick(t + 400)
  expect.equal(s.count('door'), 1)
  expect.equal(s.last('door')[2], true)
  expect.equal(r.phase, 'door_zone')
end)

test('DL-008: finish_open shares the continue branch - a primary announces and the route completes', function()
  local r, s, t = at_door('primary', 'finish_open')
  s.door_state = true
  r:tick(t + 400)
  expect.equal(s.count('announce'), 1)
  expect.equal(r.status, 'Completed')
end)

-- ================================================================ DL-013 (TAC events)
-- Expectations come from DL-013: opt-in (no event is the default), before fires on arrival ahead of the action,
-- after fires at completion inside advance(), check-first and verified through the status query, at most 3
-- attempts (first plus 2 retries), an unconfirmed pause proceeds with a loud log, an unconfirmed run fails to
-- Error, Start/Resume are blocked and explained during a TAC phase, combat is ignored there, and a TAC left
-- paused is logged. The wait lengths and retry spacing are implementation choices, so tests use generous limits.
local function tick_until(r, t, limit_ms, done)
  local started = t
  while t - started < limit_ms and not done() do
    t = t + 100
    r:tick(t)
  end
  return t
end

local function tac_calls(s) return s.count('tac_command') + s.count('tac_query') end

local function has_log(s, needle)
  for _, l in ipairs(s.logs) do if l:find(needle, 1, true) then return true end end
  return false
end

local function first_index(names, name)
  for i, n in ipairs(names) do if n == name then return i end end
end

local function last_index(names, name)
  for i = #names, 1, -1 do if names[i] == name then return i end end
end

-- Runner standing at a ground traverse that has the given TAC events, arrival tick done.
local function at_tac_before(extra, tweak)
  local rt = ground_route(nil, extra or { tac_before = 'pause' })
  local s = Sim.new()
  if tweak then tweak(s) end
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  r:tick(1100)
  return r, s, 1100, rt
end

test('DL-013: a route with no events makes zero TAC calls and logs no TAC state', function()
  local s = Sim.new()
  local r = Core.new(far_route(), s.io)
  r:start(1, 1000)
  s.p = { x = 0, y = -200, z = 0 }
  r:tick(1100)
  s.p = { x = 0, y = -400, z = 0 }
  r:tick(1200)
  expect.equal(r.status, 'Completed')
  expect.equal(tac_calls(s), 0)
  r:stop()
  expect.falsy(has_log(s, 'TAC left paused'))
end)

test('DL-013: tac_before pause is confirmed before facing for the fall begins', function()
  local r, s, t = at_tac_before()
  expect.equal(r.phase, 'tac_before')
  expect.equal(s.count('face'), 0)
  tick_until(r, t, 10000, function() return r.phase == 'traverse_facing' end)
  expect.equal(r.phase, 'traverse_facing')
  expect.equal(s.count('tac_command'), 1)
  expect.equal(s.last('tac_command')[1], 'pause')
  local names = s.names()
  expect.truthy(last_index(names, 'tac_query') < first_index(names, 'face'))   -- verified, then the action
end)

test('DL-013: check-first - no command is sent when TAC already reports the goal state', function()
  local r, s, t = at_tac_before(nil, function(sim) sim.tac_actual = 'paused' end)
  tick_until(r, t, 10000, function() return r.phase == 'traverse_facing' end)
  expect.equal(r.phase, 'traverse_facing')
  expect.equal(s.count('tac_command'), 0)
end)

test('DL-013: an unconfirmed pause is retried up to 3 attempts in total, then proceeds with a loud log', function()
  local r, s, t = at_tac_before(nil, function(sim) sim.tac_applies = false end)
  tick_until(r, t, 60000, function() return r.phase == 'traverse_facing' end)
  expect.equal(r.phase, 'traverse_facing')          -- proceeded
  expect.equal(s.count('tac_command'), 3)           -- first attempt plus 2 retries
  expect.truthy(has_log(s, 'proceeding'))
  expect.truthy(has_log(s, 'pause'))
end)

test('DL-013: a status query that is never answered counts as unconfirmed; the pause still proceeds after 3 attempts', function()
  local r, s, t = at_tac_before(nil, function(sim) sim.tac_answers = false end)
  local t_end = tick_until(r, t, 120000, function() return r.phase == 'traverse_facing' end)
  expect.equal(r.phase, 'traverse_facing')
  expect.equal(s.count('tac_command'), 3)
  expect.truthy(t_end - t >= 5000)                  -- at least one full answer timeout elapsed
  expect.truthy(has_log(s, 'proceeding'))
end)

test('DL-013: an unconfirmed run fails the leg to Error naming TAC and run', function()
  local rt = route({ wp('wp_001', 0, 0, 0, { tac_after = 'run' }), wp('wp_002', 0, -100, 0, { type = 'finish', radius = 5 }) })
  local s = Sim.new()
  s.tac_actual, s.tac_applies = 'paused', false
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  r:tick(1100)
  tick_until(r, 1100, 120000, function() return r.status == 'Error' end)
  expect.equal(r.status, 'Error')
  T.assert_contains(r.message, 'TAC')
  T.assert_contains(r.message, 'run')
  expect.equal(s.count('tac_command'), 3)
end)

test('DL-013: tac_after on a traversal fires after the exit is reached and before the next leg', function()
  local rt = ground_route(nil, { tac_after = 'run' })
  rt.waypoints[2] = wp('wp_002', 0, -160, -40, { type = 'finish', radius = 5 })
  local r, s, t = to_phase(rt, 'ground_exit')
  s.tac_actual = 'paused'
  local exit = rt.waypoints[1].exit
  s.p = { x = exit.x, y = exit.y, z = exit.z }
  r:tick(t + 100)
  expect.equal(r.phase, 'tac_after')
  expect.truthy(s.last('nav')[1] == exit)            -- no leg to the next waypoint yet
  tick_until(r, t + 100, 10000, function() return r.phase ~= 'tac_after' end)
  expect.equal(s.last('tac_command')[1], 'run')
  expect.equal(s.last('nav')[1].id, 'wp_002')        -- the next leg starts only after the run is confirmed
end)

test('DL-013: tac_after on a finish waypoint fires before Completed', function()
  local rt = route({ wp('wp_001', 0, -200, 0, { radius = 5 }),
    wp('wp_002', 0, -400, 0, { type = 'finish', radius = 5, tac_after = 'run' }) })
  local s = Sim.new()
  s.tac_actual = 'paused'
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  s.p = { x = 0, y = -200, z = 0 }
  r:tick(1100)
  s.p = { x = 0, y = -400, z = 0 }
  r:tick(1200)
  expect.equal(r.phase, 'tac_after')
  expect.equal(r.status, 'Running')                  -- not Completed until the run is confirmed
  tick_until(r, 1200, 10000, function() return r.status == 'Completed' end)
  expect.equal(r.status, 'Completed')
  expect.equal(s.last('tac_command')[1], 'run')
end)

local function span_route()
  return route({ wp('wp_001', 0, -100, 0, { radius = 5, tac_before = 'pause' }),
    wp('wp_002', 0, -200, 0, { radius = 5 }), wp('wp_003', 0, -300, 0, { type = 'finish', radius = 5 }) })
end

test('DL-013: Start asserts the effective TAC state when an earlier event set one', function()
  local s = Sim.new()
  local r = Core.new(span_route(), s.io)
  r:start(2, 1000)
  expect.equal(r.phase, 'tac_assert')
  tick_until(r, 1000, 10000, function() return r.phase == 'nav' end)
  expect.equal(r.phase, 'nav')
  expect.equal(s.count('tac_command'), 1)
  expect.equal(s.last('tac_command')[1], 'pause')
  expect.equal(s.last('nav')[1].id, 'wp_002')
end)

test('DL-013: Start asserts nothing when no event is at or before the starting point', function()
  local s = Sim.new()
  local r = Core.new(span_route(), s.io)
  r:start(1, 1000)                                    -- wp_001's own "before" fires on arrival, not at Start
  expect.equal(r.phase, 'nav')
  expect.equal(tac_calls(s), 0)
end)

test('DL-013: backtrack inside a span sends no redundant command (check-first)', function()
  local rt = route({ wp('wp_001', 0, -100, 0, { radius = 5 }),
    wp('wp_002', 0, -200, 0, { radius = 5, tac_before = 'pause' }), wp('wp_003', 0, -300, 0, { type = 'finish', radius = 5 }) })
  local s = Sim.new()
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  s.p = { x = 0, y = -100, z = 0 }; r:tick(1100)      -- wp_001 done, leg to wp_002
  s.p = { x = 0, y = -200, z = 0 }
  local t = tick_until(r, 1100, 10000, function() return r.phase == 'nav' and r.index == 3 end)
  expect.equal(r.index, 3)
  expect.equal(s.tac_actual, 'paused')
  expect.equal(s.count('tac_command'), 1)
  s.nav_active = false                                -- the leg to wp_003 stalls until it backtracks
  t = tick_until(r, t, 60000, function() return r.phase == 'backtrack' end)
  expect.equal(r.phase, 'backtrack')
  s.nav_active = true
  s.p = { x = 0, y = -200, z = 0 }
  tick_until(r, t, 10000, function() return r.phase == 'nav' end)
  expect.equal(s.count('tac_command'), 1)             -- nothing redundant
  expect.equal(s.count('tac_query'), 3)               -- 2 at the first arrival, 1 check-first at the backtrack
end)

test('DL-013: Start, Resume and Use-Nearest are blocked during a TAC phase with a reason naming the state and attempt', function()
  local r, s, t = at_tac_before(nil, function(sim) sim.tac_applies = false end)
  expect.equal(r.phase, 'tac_before')
  local before = #s.calls
  r:start(1, t + 10)
  T.assert_contains(r.message, 'Start/Resume blocked')
  T.assert_contains(r.message, 'TAC')
  T.assert_contains(r.message, 'paused')
  T.assert_contains(r.message, 'attempt 1 of 3')
  r:resume(t + 20)
  T.assert_contains(r.message, 'Start/Resume blocked')
  r:start_nearest(t + 30)
  T.assert_contains(r.message, 'Start/Resume blocked')
  expect.equal(#s.calls, before)                       -- nothing was touched
  expect.truthy(has_log(s, 'Start/Resume blocked'))   -- every blocked press is logged
end)

test('DL-013: the blocked-press note stays visible when the phase updates for a retry', function()
  local r, s, t = at_tac_before(nil, function(sim) sim.tac_applies = false end)
  r:start(1, t + 10)
  tick_until(r, t, 30000, function() return r.message:find('attempt 2 of 3', 1, true) ~= nil end)
  T.assert_contains(r.message, 'attempt 2 of 3')
  T.assert_contains(r.message, 'Start/Resume')
end)

test('DL-013: combat has no effect during a TAC phase', function()
  local function next_tick(combat)
    local r, s, t = at_tac_before()
    s.combat = combat
    r:tick(t + 100)
    return { status = r.status, phase = r.phase, message = r.message, calls = s.names() }
  end
  local with_combat, without = next_tick(true), next_tick(false)
  expect.equal(with_combat, without)
  expect.equal(with_combat.phase, 'tac_before')
end)

test('DL-013: stopping while TAC is paused logs "TAC left paused"', function()
  local r, s, t = at_tac_before()
  tick_until(r, t, 10000, function() return r.phase == 'traverse_facing' end)
  expect.equal(s.tac_actual, 'paused')
  r:stop()
  expect.truthy(has_log(s, 'TAC left paused'))
end)

test('DL-013: an error while TAC is paused logs "TAC left paused"', function()
  local r, s, t = at_tac_before()
  tick_until(r, t, 10000, function() return r.phase == 'traverse_facing' end)
  s.zone = 'elsewhere'
  r:tick(t + 20000)
  expect.equal(r.status, 'Error')
  expect.truthy(has_log(s, 'TAC left paused'))
end)

test('DL-013: completion messages make no claim about TAC', function()
  local s = Sim.new()
  local r = Core.new(far_route(), s.io)
  r:start(1, 1000)
  s.p = { x = 0, y = -200, z = 0 }; r:tick(1100)
  s.p = { x = 0, y = -400, z = 0 }; r:tick(1200)
  expect.equal(r.status, 'Completed')
  expect.falsy(r.message:find('TAC', 1, true))
  -- finish_zone completion
  local zs = Sim.new()
  local zr = Core.new(route({ wp('wp_001', 0, 0, 0, { type = 'door', door_after = 'finish_zone',
    door = { id = 9, name = 'z', x = 1, y = 1, z = 1 } }) }), zs.io)
  zr:start(1, 1000); zr:tick(1100); zs.door_state = false; zr:tick(1500)
  expect.equal(zr.phase, 'door_zone')
  zs.zone = 'bazaar'; zr:tick(1600)
  expect.equal(zr.status, 'Completed')
  expect.falsy(zr.message:find('TAC', 1, true))
end)

-- The UI grays Start / Use Nearest Waypoint / Resume exactly while Start would be blocked by a TAC phase
-- (DL-013 Blocking). `tac_busy()` is what it reads; it must not stay true after the phase ends or fails.
test('DL-013: tac_busy is true exactly while PTAR is setting TAC', function()
  local fresh = Core.new(far_route(), Sim.new().io)
  expect.equal(fresh:tac_busy(), false)                    -- nothing running: not busy
  local r, s, t = at_tac_before()
  expect.equal(r:tac_busy(), true)
  r:start(1, t + 10)
  T.assert_contains(r.message, 'Start/Resume blocked')      -- the block and the flag agree
  tick_until(r, t, 10000, function() return r.phase == 'traverse_facing' end)
  expect.equal(r:tac_busy(), false)                        -- phase finished
end)

test('DL-013: tac_busy is false after an unconfirmed run fails the leg, so the buttons come back', function()
  local rt = route({ wp('wp_001', 0, 0, 0, { tac_after = 'run' }), wp('wp_002', 0, -100, 0, { type = 'finish', radius = 5 }) })
  local s = Sim.new()
  s.tac_actual, s.tac_applies = 'paused', false
  local r = Core.new(rt, s.io)
  r:start(1, 1000)
  r:tick(1100)
  expect.equal(r:tac_busy(), true)
  tick_until(r, 1100, 120000, function() return r.status == 'Error' end)
  expect.equal(r.status, 'Error')
  expect.equal(r:tac_busy(), false)
  r:start(1, 200000)                                       -- not blocked by a stale TAC phase
  expect.falsy(r.message:find('Setting TAC', 1, true))
  expect.falsy(r.message:find('blocked', 1, true))
end)

test('DL-013: tac_busy is false after Stop or Pause during a TAC phase', function()
  local r1 = at_tac_before()
  r1:stop()
  expect.equal(r1:tac_busy(), false)
  local r2 = at_tac_before()
  r2:pause()
  expect.equal(r2:tac_busy(), false)
end)

-- DL-001 usability fix (found live, 2026-09-28): the traversal-block message was a one-shot say() that got
-- silently overwritten by the traversal's own routine progress narration within a couple of seconds, so the
-- explanation for why Start/Resume/Use-Nearest did nothing was easy to miss. Fix mirrors DL-013's tac_busy()
-- pattern: a live, always-recomputed query the UI reads every frame, independent of the transient message.
test('DL-001 usability fix: traversal_blocking() is true exactly during each of the 7 traversal phases', function()
  for _, phase in ipairs(TRAVERSAL_PHASES) do
    local r = to_phase(water_route(), phase)
    expect.equal(r.phase, phase)
    expect.equal(r:traversal_blocking(), true)
  end
end)

test('DL-001 usability fix: traversal_blocking() is false outside traversal phases', function()
  local s = Sim.new()
  local r = Core.new(far_route(), s.io)
  expect.equal(r:traversal_blocking(), false)   -- fresh
  r:start(1, 1000)
  expect.equal(r:traversal_blocking(), false)   -- ordinary nav
end)

test('DL-001 usability fix: traversal_blocking() stays true across the routine narration that overwrote the old message', function()
  -- Reproduces the exact live scenario: drive to traverse_falling, let the water drop's own progress messages
  -- fire (landing, facing underwater, descending) -- the query must not depend on self.message at all.
  local r, s, t = to_phase(water_route(), 'traverse_falling')
  expect.equal(r:traversal_blocking(), true)
  s.feet, s.head, s.p.z = true, true, -60
  t = tick_until(r, t, 10000, function() return r.phase == 'water_descend' or r.phase == 'water_cross' end)
  expect.equal(r:traversal_blocking(), true)   -- still blocking, regardless of how many progress messages fired
end)

test('DL-001 usability fix: traversal_blocking() clears once the traversal is left (Completed)', function()
  -- Exit placed exactly where the simulated fall lands (0,0,-30) so landing advances straight to the finish,
  -- with no separate ground_exit nav leg to simulate.
  local rt = ground_route({ x = 0, y = 0, z = -30, radius = 5 })
  rt.waypoints[2] = wp('wp_002', 0, 0, -30, { type = 'finish', radius = 5 })
  local r, s, t = to_phase(rt, 'landed')
  tick_until(r, t, 10000, function() return r.status == 'Completed' end)
  expect.equal(r.status, 'Completed')
  expect.equal(r:traversal_blocking(), false)
end)

-- ================================================================ DL-010 (waypoint barrier sync)
-- Expectations come from DL-010: REACHED sent unconditionally on arrival before the barrier is evaluated;
-- solo (empty roster) releases immediately; barrier waits until every roster name has been seen; timeout
-- proceeds anyway with a loud log; barrier sits before tac_before and the waypoint's own action (agreed order);
-- door confirmation is cleared on release at a door waypoint; barrier-wait is unguarded for Start/Resume/
-- Use-Nearest and gets ordinary combat pause-and-resume, unlike the TAC/traversal phases.
local BARRIER_TIMEOUT_MS = 120000

-- A route whose first waypoint sits at the Sim's default starting position (0,0,0), so Start() arrives
-- immediately (navigate()'s "already within radius" branch) instead of beginning a nav leg.
local function at_start_route()
  return route({ wp('wp_001', 0, 0, 0, { radius = 5 }), wp('wp_002', 0, -100, 0, { type = 'finish', radius = 5 }) })
end

local function arrive_at_first_waypoint(rt, tweak)
  local s = Sim.new()
  if tweak then tweak(s) end
  local r = Core.new(rt or at_start_route(), s.io)
  r:start(1, 1000)
  r:tick(1100)   -- Start()'s "already within radius" branch only sets phase='nav'; arrival is detected next tick.
  return r, s, 1100
end

test('DL-010: REACHED is announced immediately on arrival, before the barrier is evaluated', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  expect.equal(r.phase, 'barrier_wait')
  expect.equal(s.count('barrier_announce'), 1)
  expect.equal(s.last('barrier_announce')[1], 'wp_001')
end)

test('DL-010: a solo run (empty roster) releases the barrier immediately', function()
  local r, s, t = arrive_at_first_waypoint(nil)
  expect.equal(r.phase, 'nav')   -- past the barrier and already navigating on to the next waypoint
  expect.equal(s.count('nav'), 1)   -- the leg to wp_002 (wp_001 itself was already within radius at Start)
end)

test('DL-010: with a required teammate not yet seen, the barrier holds and does not dispatch the action', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  r:tick(t + 100)
  expect.equal(r.phase, 'barrier_wait')
  expect.equal(r.status, 'Running')
end)

test('DL-010: once the missing teammate\'s REACHED is seen, the barrier releases on the next tick', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  r:tick(t + 100)
  expect.equal(r.phase, 'barrier_wait')
  s.barrier_seen_map['wp_001'] = { Bob = true }
  r:tick(t + 200)
  expect.equal(r.phase, 'nav')
end)

test('DL-010: a barrier release is logged with the roster expected and the names seen', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  s.barrier_seen_map['wp_001'] = { Bob = true }
  r:tick(t + 100)
  expect.truthy(has_log(s, 'wp_001'))
  expect.truthy(has_log(s, 'Bob'))
end)

test('DL-010: an unmet barrier proceeds after the timeout, with a loud log naming who was missing', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  local t_end = tick_until(r, t, BARRIER_TIMEOUT_MS + 5000, function() return r.phase ~= 'barrier_wait' end)
  expect.equal(r.phase, 'nav')
  expect.truthy(t_end - t >= BARRIER_TIMEOUT_MS)
  expect.truthy(has_log(s, 'Bob'))
  expect.truthy(has_log(s, 'TIMEOUT') or has_log(s, 'timeout'))
end)

test('DL-010: barrier release happens before tac_before, preserving the agreed arrival order', function()
  local rt = route({ wp('wp_001', 0, 0, 0, { radius = 5, tac_before = 'pause' }),
    wp('wp_002', 0, -400, 0, { type = 'finish', radius = 5 }) })
  local r, s, t = arrive_at_first_waypoint(rt, function(sim) sim.barrier_roster = { 'Bob' } end)
  expect.equal(r.phase, 'barrier_wait')
  expect.equal(s.count('tac_command'), 0)   -- TAC has not been touched while the barrier is still waiting
  s.barrier_seen_map['wp_001'] = { Bob = true }
  r:tick(t + 100)
  expect.equal(r.phase, 'tac_before')   -- barrier released, tac_before now begins
end)

test('DL-010: at a door waypoint, barrier release clears that door\'s stale confirmation before the door phase begins', function()
  local rt = route({ wp('wp_001', 0, 0, 0, { type = 'door', door_after = 'continue',
    door = { id = 77, name = 'd', x = 1, y = 1, z = 1 } }), wp('wp_002', 0, -100, 0, { type = 'finish', radius = 5 }) })
  local r, s, t = arrive_at_first_waypoint(rt, function(sim)
    sim.confirmed[77] = true   -- stale from an earlier run
    sim.barrier_roster = { 'Bob' }   -- delay release so the before/after state is actually observable
  end)
  expect.equal(r.phase, 'barrier_wait')
  expect.equal(s.confirmed[77], true)   -- not cleared yet -- the barrier hasn't released
  s.barrier_seen_map['wp_001'] = { Bob = true }
  r:tick(t + 100)
  expect.equal(r.phase, 'door')
  expect.equal(s.confirmed[77], nil)   -- cleared on release, before the door phase began
  expect.truthy(s.count('clear_door_confirmed') >= 1)
end)

test('DL-010: a door waypoint also clears a stale confirmation when the barrier releases via timeout', function()
  local rt = route({ wp('wp_001', 0, 0, 0, { type = 'door', door_after = 'continue',
    door = { id = 88, name = 'd', x = 1, y = 1, z = 1 } }), wp('wp_002', 0, -100, 0, { type = 'finish', radius = 5 }) })
  local r, s, t = arrive_at_first_waypoint(rt, function(sim)
    sim.confirmed[88] = true
    sim.barrier_roster = { 'Bob' }   -- Bob never sends REACHED, so the barrier must time out
  end)
  tick_until(r, t, BARRIER_TIMEOUT_MS + 5000, function() return r.phase ~= 'barrier_wait' end)
  expect.equal(r.phase, 'door')
  expect.equal(s.confirmed[88], nil)
end)

test('DL-010: Start, Resume and Use-Nearest are NOT blocked during barrier-wait (unlike TAC/traversal phases)', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  expect.equal(r.phase, 'barrier_wait')
  expect.equal(r:tac_busy(), false)
  expect.equal(r:traversal_blocking(), false)
  r:start(1, t + 10)
  expect.falsy(r.message:find('blocked', 1, true))
end)

test('DL-010: combat during barrier-wait pauses and resumes normally, joining the nav/door/ground_exit group', function()
  local r, s, t = arrive_at_first_waypoint(nil, function(sim) sim.barrier_roster = { 'Bob' } end)
  s.combat = true
  r:tick(t + 100)
  expect.equal(r.status, 'Waiting for combat')
  expect.equal(r.phase, 'combat')
  s.combat = false
  local navs_before = s.count('nav')
  local announces_before = s.count('barrier_announce')
  r:tick(t + 200)      -- combat first reads clear; starts the 2000ms clear-wait
  r:tick(t + 2300)     -- past the 2000ms combat-clear delay
  expect.equal(r.phase, 'barrier_wait')   -- resumes straight back into the wait, not through navigate()
  expect.equal(s.count('nav'), navs_before)              -- no re-issued /nav for a stationary wait
  expect.equal(s.count('barrier_announce'), announces_before)   -- no redundant re-announce
  s.barrier_seen_map['wp_001'] = { Bob = true }
  r:tick(t + 2400)
  expect.equal(r.phase, 'nav')   -- now released and past the barrier
end)

test('DL-010: barrier state is cleared at Start so a second run does not pass every waypoint instantly', function()
  local s = Sim.new()
  local r = Core.new(far_route(), s.io)
  r:start(1, 1000)
  expect.equal(s.count('barrier_clear'), 1)
end)

test('DL-010: heartbeat_active() is true only while actively trying to complete the route', function()
  local active_route = far_route()
  local function status_after(setup)
    local s = Sim.new()
    local r = Core.new(active_route, s.io)
    setup(r, s)
    return r.status, r:heartbeat_active()
  end
  local st, active = status_after(function(r, s) r:start(1, 1000) end)
  expect.equal(st, 'Running'); expect.equal(active, true)

  st, active = status_after(function(r, s) r:start(1, 1000); s.combat = true; r:tick(1100) end)
  expect.equal(st, 'Waiting for combat'); expect.equal(active, true)

  st, active = status_after(function(r, s) r:start(1, 1000); r:pause() end)
  expect.equal(st, 'Paused'); expect.equal(active, false)

  st, active = status_after(function(r, s) r:start(1, 1000); r:stop() end)
  expect.equal(st, 'Ready'); expect.equal(active, false)

  st, active = status_after(function(r, s) end)   -- fresh, never started
  expect.equal(active, false)

  st, active = status_after(function(r, s)
    r:start(1, 1000)
    s.zone = 'elsewhere'   -- forces an Error via the zone check
    r:tick(1100)
  end)
  expect.equal(st, 'Error'); expect.equal(active, false)
end)
