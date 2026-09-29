-- TAC status-query bookkeeping (DL-013). No MacroQuest dependency: PTAR.lua wires it to mq.event and mq.cmd.
-- A command is verified through the answer to `/ac status`, never through TAC's own acknowledgement line. A status
-- line only counts while a query is active; anything else (a duplicate copy of a line, a line caused by the user
-- typing `/ac status`, a stale answer) is ignored and logged. Same shape as PTDeathRecovery's status handling.
local M = {}

local function trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.new(log)
  local self = { active = false, answer = nil }

  -- The caller flushes queued events and sends `/ac status` right after this.
  function self:begin_query()
    self.active = true
    self.answer = nil
  end

  -- Handler for the "[Triune] status: <state>, mode: <mode>, burn: <burn>" line. Returns true if it was the answer.
  function self:on_status_line(line, state, mode, burn)
    local s = trim(state):lower()
    if not self.active then
      log(string.format('TAC status line ignored (no query active): state=%s mode=%s burn=%s', s, trim(mode), trim(burn)))
      return false
    end
    self.active = false
    self.answer = { state = s, mode = trim(mode), burn = trim(burn) }
    log(string.format('TAC status answer: state=%s mode=%s burn=%s', s, trim(mode), trim(burn)))
    return true
  end

  -- The answered state, once; nil while nothing has arrived.
  function self:take()
    local a = self.answer
    self.answer = nil
    return a and a.state or nil
  end

  return self
end

return M
