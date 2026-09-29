-- Door/switch target identity matching. No MacroQuest dependency: confirms /doortarget actually selected the
-- captured door, not a stale or wrong SwitchTarget, before its Open() reading is trusted.
--
-- Position matching is X/Y only, deliberately. Real MQ2Nav door-data comparisons (2026-09-28, `reference/MQ2Nav`,
-- four zones) found: door/switch IDs are unique within a zone (zero collisions across 177 objects in Sleeper's
-- Tomb, two Neriak files and Permafrost), so id+name is a reliable identity check on its own; several zones have
-- a distinctly-typed, distinctly-named door-like object (Sleeper's Tomb `SHRINEGATE200`, Neriak's `HHCELL`,
-- Permafrost's `PORT1414`/`PORT2814`/`PORT5628`/`TOGGLE`) that travels far in Z when it opens (a portcullis-style
-- gate, not a hinged door). Matching Z against a single captured (closed-state) position produced a false
-- "Target mismatch" on exactly this kind of door the moment it opened -- the live incident this module fixes
-- (Sleeper's Tomb door #44, 2026-09-28). No safe max-Z-travel value is known across gate types, so Z is dropped
-- from the match entirely rather than widened to another guessed tolerance.
local M = {}

local POSITION_TOLERANCE = 10 -- unchanged from the original 3D check; now applied to X/Y only

-- observed: {id, name, x, y} read live from SwitchTarget. captured: {id, name, x, y, ...} from the route's
-- captured door data. Returns true, or false plus a detail string naming what did not match.
function M.matches(observed, captured)
  if not observed or not captured then return false, 'missing data' end
  if observed.id ~= captured.id then
    return false, string.format('id mismatch: expected %s, observed %s', tostring(captured.id), tostring(observed.id))
  end
  if observed.name ~= captured.name then
    return false, string.format('name mismatch: expected %s, observed %s', tostring(captured.name), tostring(observed.name))
  end
  if type(observed.x) ~= 'number' or type(observed.y) ~= 'number' then
    return false, 'position unavailable'
  end
  local dx, dy = observed.x - captured.x, observed.y - captured.y
  local offset = math.sqrt(dx * dx + dy * dy)
  if offset > POSITION_TOLERANCE then
    return false, string.format('position mismatch: expected %.1f,%.1f observed %.1f,%.1f offset %.1f',
      captured.x, captured.y, observed.x, observed.y, offset)
  end
  return true
end

return M
