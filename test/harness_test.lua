-- Self-tests for the helper API in test/harness/t.lua (DL-012 "Helpers").
local T = require 'harness.t'
local fs = require 'harness.fs'
local test, expect = T.test, T.expect

test('near accepts values within epsilon and rejects values outside it', function()
  T.near(0.1 + 0.2, 0.3, 1e-9)
  expect.fail(function() T.near(1, 2, 0.5) end, 'expected')
end)

test('assert_contains is a plain substring match (a needle ending in % is safe)', function()
  T.assert_contains('100% wrong', '100%')
  expect.fail(function() T.assert_contains('abc', 'abd') end, 'to contain')
end)

test('patch replaces a value for the test and cleanups restore it', function()
  local t = { x = 1 }
  T.patch(t, 'x', 2)
  expect.equal(t.x, 2)
  -- Restoration is observed by the next test below via the shared fixture.
  _G.__patch_probe = t
end)

test('patch from the previous test was undone by its cleanup', function()
  expect.equal(_G.__patch_probe.x, 1)
  _G.__patch_probe = nil
end)

test('with_temp_dir creates a directory under %TEMP% and removes it afterwards', function()
  local dir = T.with_temp_dir()
  expect.truthy(fs.exists(dir))
  local temp = os.getenv('TEMP'):lower():gsub('\\+$', '')
  expect.equal(dir:lower():sub(1, #temp), temp)
  _G.__tmp_probe = dir
end)

test('the temp dir from the previous test is gone', function()
  expect.falsy(fs.exists(_G.__tmp_probe))
  _G.__tmp_probe = nil
end)

test('fresh_require returns a new table and leaves a consistent module tree', function()
  local before = require('PTAR.PTARRouteData')
  local files = T.fresh_require('PTAR.PTARFiles')
  local after = require('PTAR.PTARRouteData')
  expect.truthy(before ~= after)
  -- PTARFiles must be using the same (new) RouteData table that require() now returns.
  after.read = function() return nil, 'FRESH table' end
  local _, err = files.add('.', 'PTAR_x.lua')
  T.assert_contains(err, 'FRESH table')
end)
