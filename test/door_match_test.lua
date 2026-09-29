-- Requirement tests for PTARDoorMatch. Expectations come from real MQ2Nav door-data comparisons (2026-09-28,
-- `reference/MQ2Nav`): door/switch IDs are unique within a zone (zero collisions across 177 objects in 4 zones:
-- Sleeper's Tomb, Neriak x2, Permafrost), so id+name is a reliable identity check; several zones have a
-- distinctly-typed, distinctly-named door-like object (Sleeper's SHRINEGATE200, Neriak's HHCELL, Permafrost's
-- PORT.../TOGGLE) that travels significantly in Z when it opens, so matching Z against a single captured
-- (closed-state) position produces a false mismatch once such a door is open. The fix: identity is id + name +
-- X/Y position only; Z is never part of the match.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local Match = require 'PTAR.PTARDoorMatch'

local function captured() return { id = 44, name = 'SHRINEGATE200', x = -791.471, y = -2383.480, z = -991.998 } end

test('an exact match on id, name, x and y succeeds', function()
  local ok = Match.matches({ id = 44, name = 'SHRINEGATE200', x = -791.471, y = -2383.480 }, captured())
  expect.equal(ok, true)
end)

test('a large Z difference does NOT cause a mismatch (the actual fix): a door that travels far in Z when open', function()
  -- Same id/name/x/y as the closed-state capture; z is wildly different, simulating SHRINEGATE200 open.
  local ok = Match.matches({ id = 44, name = 'SHRINEGATE200', x = -791.471, y = -2383.480, z = -969.99 }, captured())
  expect.equal(ok, true)
end)

test('a mismatched id fails, naming both ids', function()
  local ok, detail = Match.matches({ id = 99, name = 'SHRINEGATE200', x = -791.471, y = -2383.480 }, captured())
  expect.equal(ok, false)
  T.assert_contains(detail, '44')
  T.assert_contains(detail, '99')
end)

test('a mismatched name fails even when the id matches (a numbering collision guard)', function()
  local ok, detail = Match.matches({ id = 44, name = 'SOMETHINGELSE', x = -791.471, y = -2383.480 }, captured())
  expect.equal(ok, false)
  T.assert_contains(detail, 'SHRINEGATE200')
  T.assert_contains(detail, 'SOMETHINGELSE')
end)

test('a small X/Y offset within tolerance still matches', function()
  local ok = Match.matches({ id = 44, name = 'SHRINEGATE200', x = -791.471 + 3, y = -2383.480 - 3 }, captured())
  expect.equal(ok, true)
end)

test('an X offset beyond tolerance fails, even with the correct id and name', function()
  local ok, detail = Match.matches({ id = 44, name = 'SHRINEGATE200', x = -791.471 + 50, y = -2383.480 }, captured())
  expect.equal(ok, false)
  T.assert_contains(detail, 'position')
end)

test('a Y offset beyond tolerance fails on its own (Y is not silently ignored)', function()
  local ok, detail = Match.matches({ id = 44, name = 'SHRINEGATE200', x = -791.471, y = -2383.480 + 50 }, captured())
  expect.equal(ok, false)
  T.assert_contains(detail, 'position')
end)

test('a missing observed position fails rather than matching by accident', function()
  local ok, detail = Match.matches({ id = 44, name = 'SHRINEGATE200', x = nil, y = nil }, captured())
  expect.equal(ok, false)
  T.assert_contains(detail, 'position')
end)

test('nil observed data fails cleanly', function()
  local ok, detail = Match.matches(nil, captured())
  expect.equal(ok, false)
end)
