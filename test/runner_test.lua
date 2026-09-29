-- Requirement-level tests of the test tooling itself (DL-012): the runner's exit codes and guards.
-- Source of each expectation: DL-012 "Exit codes" and "Guards" (an unusable run must never look like a pass).
local T = require 'harness.t'
local fs = require 'harness.fs'
local test, expect = T.test, T.expect

local root = T.root
local BS = string.char(92)

-- Writes fixture files into a fresh temp dir, runs the real runner on it, returns exit code + output.
local function run_fixture(files)
  local dir = T.with_temp_dir()
  for name, body in pairs(files) do
    local f = assert(io.open(dir .. BS .. name, 'wb'))
    f:write(body)
    f:close()
  end
  local outfile = os.tmpname()
  T.on_cleanup(function() os.remove(outfile) end)
  local cmd = fs.q(arg[-1]) .. ' ' .. fs.q(root .. '/test/harness/run.lua') .. ' ' .. fs.q(dir) ..
    ' > ' .. fs.q(outfile) .. ' 2>&1'
  local code = fs.execute(cmd)
  return code, fs.read_all(outfile) or '', dir
end

local HEAD = "local T = require 'harness.t'\nlocal test, skip, expect = T.test, T.skip, T.expect\n"

test('a directory of passing tests exits 0 and reports PASS', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD .. "test('ok', function() expect.equal(1, 1) end)\n" })
  expect.equal(code, 0)
  T.assert_contains(out, 'RESULT: PASS')
end)

test('a failing test exits 20 and names the failure', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD .. "test('bad', function() expect.equal(1, 2) end)\n" })
  expect.equal(code, 20)
  T.assert_contains(out, 'FAIL (tests failed)')
  T.assert_contains(out, 'RESULT: FAIL')
end)

test('later tests still run after an earlier failure in the same file', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD ..
    "test('bad', function() expect.equal(1, 2) end)\ntest('good', function() end)\n" })
  expect.equal(code, 20)
  T.assert_contains(out, 'ran=2 passed=1 failed=1')
end)

test('a syntax error in a test file is a load error, not a test failure', function()
  local code, out = run_fixture({ ['a_test.lua'] = 'this is not lua\n' })
  expect.equal(code, 20)
  T.assert_contains(out, 'FAIL (load error)')
end)

test('an error raised in a file body (outside any test) is a load error', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD .. "error('body boom')\n" })
  expect.equal(code, 20)
  T.assert_contains(out, 'FAIL (load error)')
  T.assert_contains(out, 'body boom')
end)

test('a file that registers zero tests fails', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD })
  expect.equal(code, 20)
  T.assert_contains(out, 'FAIL (no tests ran)')
end)

test('a file that exits 0 without running the harness to completion fails', function()
  local code, out = run_fixture({ ['a_test.lua'] = 'os.exit(0)\n' })
  expect.equal(code, 20)
  T.assert_contains(out, 'exit 0 but no summary line')
end)

test('a crash (exit 1) is reported as a crash, not as a failed test', function()
  local code, out = run_fixture({ ['a_test.lua'] = 'os.exit(1)\n' })
  expect.equal(code, 20)
  T.assert_contains(out, 'CRASH/LAUNCH FAILURE (exit 1)')
end)

test('an empty test directory fails the runner guard (exit 21)', function()
  local dir = T.with_temp_dir()
  local outfile = os.tmpname()
  T.on_cleanup(function() os.remove(outfile) end)
  local code = fs.execute(fs.q(arg[-1]) .. ' ' .. fs.q(root .. '/test/harness/run.lua') .. ' ' .. fs.q(dir) ..
    ' > ' .. fs.q(outfile) .. ' 2>&1')
  expect.equal(code, 21)
  T.assert_contains(fs.read_all(outfile), 'no .lua files found')
end)

test('a misnamed .lua file in the test directory fails the guard (exit 21)', function()
  local code, out = run_fixture({
    ['a_test.lua'] = HEAD .. "test('ok', function() end)\n",
    ['helpers.lua'] = 'return {}\n',
  })
  expect.equal(code, 21)
  T.assert_contains(out, 'does not match *_test.lua')
end)

test('skips are counted separately and never as ran', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD ..
    "test('ok', function() end)\nskip('later', 'DL-010 not implemented')\nskip('later2', 'DL-010 not implemented')\n" })
  expect.equal(code, 0)
  T.assert_contains(out, 'ran=1 passed=1 failed=0 skipped=2')
  T.assert_contains(out, 'SKIPPED: DL-010 not implemented')
end)

test('a file containing only skips fails (skips do not count as tests that ran)', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD .. "skip('later', 'reason')\n" })
  expect.equal(code, 20)
  T.assert_contains(out, 'FAIL (no tests ran)')
end)

test('skip() without a reason is rejected', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD .. "test('ok', function() end)\nskip('later', '')\n" })
  expect.equal(code, 20)
  T.assert_contains(out, 'skip() requires a reason')
end)

test('cleanups run LIFO after a failing test', function()
  local dir = T.with_temp_dir()
  local marker = dir .. BS .. 'order.txt'
  local body = HEAD .. string.format([[
local marker = %q
local function note(s) local f = io.open(marker, 'ab'); f:write(s); f:close() end
test('fails but must still clean up', function()
  T.on_cleanup(function() note('first-registered;') end)
  T.on_cleanup(function() note('second-registered;') end)
  expect.equal(1, 2)
end)
]], marker)
  local code, _, fixture = run_fixture({ ['a_test.lua'] = body })
  expect.equal(code, 20)
  expect.equal(fs.read_all(marker), 'second-registered;first-registered;')
  local _ = fixture
end)

test('a failing cleanup fails the run even when the test itself passed', function()
  local code, out = run_fixture({ ['a_test.lua'] = HEAD ..
    "test('ok', function() T.on_cleanup(function() error('cleanup boom') end) end)\n" })
  expect.equal(code, 20)
  T.assert_contains(out, 'CLEANUP FAILED')
  T.assert_contains(out, 'cleanup boom')
end)
