-- Requirement tests for PTARBarrier (roster liveness + per-waypoint REACHED bookkeeping). Expectations come from
-- DL-010: roster membership needs both group presence and a recent heartbeat within an expiry window (item
-- "roster membership"); barrier state is a set of names per waypoint, never a counter, because each chat line
-- fires the underlying event three times (DL-008); state clears at Start so a second run does not pass instantly.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local Barrier = require 'PTAR.PTARBarrier'

test('DL-010: a name with a heartbeat inside the expiry window counts as active', function()
  local b = Barrier.new()
  b:heartbeat('Alice', 1000)
  local active = b:active_names({ 'Alice', 'Bob' }, 1000 + 14000, 15000)
  expect.equal(active, { 'Alice' })
end)

test('DL-010: a name whose heartbeat has expired does not count as active', function()
  local b = Barrier.new()
  b:heartbeat('Alice', 1000)
  local active = b:active_names({ 'Alice' }, 1000 + 15000, 15000)   -- exactly at the boundary: expired
  expect.equal(active, {})
end)

test('DL-010: a name that never sent a heartbeat is never active', function()
  local b = Barrier.new()
  local active = b:active_names({ 'Ghost' }, 999999, 15000)
  expect.equal(active, {})
end)

test('DL-010: a fresher heartbeat replaces an older one for the same name', function()
  local b = Barrier.new()
  b:heartbeat('Alice', 1000)
  b:heartbeat('Alice', 5000)
  expect.equal(b:active_names({ 'Alice' }, 5000 + 14000, 15000), { 'Alice' })
  expect.equal(b:active_names({ 'Alice' }, 1000 + 14000 + 1, 15000), { 'Alice' })   -- still fresh via the newer beat
end)

test('DL-010: recording REACHED is idempotent - repeated calls for the same name do not duplicate', function()
  local b = Barrier.new()
  b:record_reached('wp_005', 'Alice')
  b:record_reached('wp_005', 'Alice')
  b:record_reached('wp_005', 'Alice')   -- the underlying chat event fires 3 times per line (DL-008)
  local seen = b:seen_names('wp_005')
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  expect.equal(count, 1)
  expect.equal(seen.Alice, true)
end)

test('DL-010: recording REACHED for a second name at the same waypoint keeps the first (a barrier needs everyone at once)', function()
  local b = Barrier.new()
  b:record_reached('wp_005', 'Alice')
  b:record_reached('wp_005', 'Bob')
  local seen = b:seen_names('wp_005')
  expect.equal(seen.Alice, true)
  expect.equal(seen.Bob, true)
end)

test('DL-010: REACHED is tracked separately per waypoint', function()
  local b = Barrier.new()
  b:record_reached('wp_001', 'Alice')
  expect.equal(b:seen_names('wp_002').Alice, nil)
  expect.equal(b:seen_names('wp_001').Alice, true)
end)

test('DL-010: seen_names for a waypoint nobody has reached is empty, not nil', function()
  local b = Barrier.new()
  local seen = b:seen_names('wp_999')
  expect.equal(type(seen), 'table')
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  expect.equal(count, 0)
end)

test('DL-010: clear() resets REACHED state so a second run does not pass every waypoint instantly', function()
  local b = Barrier.new()
  b:record_reached('wp_001', 'Alice')
  b:clear()
  expect.equal(b:seen_names('wp_001').Alice, nil)
end)

test('DL-010: clear() does not erase heartbeat liveness (a still-running teammate stays known active)', function()
  local b = Barrier.new()
  b:heartbeat('Alice', 1000)
  b:clear()
  expect.equal(b:active_names({ 'Alice' }, 1000 + 100, 15000), { 'Alice' })
end)
