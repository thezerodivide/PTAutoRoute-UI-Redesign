-- Requirement tests for PTARTac (TAC status-query bookkeeping). Expectations come from DL-013: a command is
-- verified through the /ac status answer, never through TAC's acknowledgement; only a status line that arrives
-- while a query is active counts (the PTDR shape); anything else is ignored and logged; duplicate copies of a
-- line and stale answers must not answer a later query.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local Tac = require 'PTAR.PTARTac'

local function new_tac()
  local logs = {}
  local tac = Tac.new(function(message) logs[#logs + 1] = message end)
  return tac, logs
end

local function joined(logs) return table.concat(logs, ' | ') end

test('DL-013: a status line that arrives while a query is active is the answer', function()
  local tac = new_tac()
  tac:begin_query()
  expect.truthy(tac:on_status_line('[Triune] status: paused, mode: Manual, burn: OFF', 'paused', 'Manual', 'OFF'))
  expect.equal(tac:take(), 'paused')
end)

test('DL-013: an answer is taken once, then nothing is pending', function()
  local tac = new_tac()
  tac:begin_query()
  tac:on_status_line('l', 'running', 'Manual', 'OFF')
  expect.equal(tac:take(), 'running')
  expect.equal(tac:take(), nil)
end)

test('DL-013: nothing pending before any answer arrives', function()
  local tac = new_tac()
  tac:begin_query()
  expect.equal(tac:take(), nil)
end)

test('DL-013: a status line with no query active is ignored and logged', function()
  local tac, logs = new_tac()
  expect.falsy(tac:on_status_line('[Triune] status: running, mode: Manual, burn: OFF', 'running', 'Manual', 'OFF'))
  expect.equal(tac:take(), nil)
  T.assert_contains(joined(logs), 'ignored')
end)

test('DL-013: duplicate copies of a line after the answer do not answer anything', function()
  local tac, logs = new_tac()
  tac:begin_query()
  expect.truthy(tac:on_status_line('l', 'paused', 'Manual', 'OFF'))
  expect.equal(tac:take(), 'paused')
  expect.falsy(tac:on_status_line('l', 'paused', 'Manual', 'OFF'))   -- the second copy of the same line
  expect.equal(tac:take(), nil)
  T.assert_contains(joined(logs), 'ignored')
end)

test('DL-013: starting a new query discards a stale answer', function()
  local tac = new_tac()
  tac:begin_query()
  tac:on_status_line('l', 'running', 'Manual', 'OFF')   -- answered but never taken
  tac:begin_query()
  expect.equal(tac:take(), nil)                          -- the old answer must not satisfy the new query
end)

test('DL-013: the state is normalized to lower case without surrounding spaces', function()
  local tac = new_tac()
  tac:begin_query()
  tac:on_status_line('l', ' PAUSED ', 'Manual', 'OFF')
  expect.equal(tac:take(), 'paused')
end)

test('DL-013: an unrecognized state is passed through so it can be logged and treated as unconfirmed', function()
  local tac = new_tac()
  tac:begin_query()
  tac:on_status_line('l', 'Exploding', 'Manual', 'OFF')
  expect.equal(tac:take(), 'exploding')
end)

test('DL-013: every accepted answer is logged with state, mode and burn', function()
  local tac, logs = new_tac()
  tac:begin_query()
  tac:on_status_line('l', 'paused', 'Assist (Chase)', 'OFF')
  local text = joined(logs)
  T.assert_contains(text, 'paused')
  T.assert_contains(text, 'Assist (Chase)')
end)
