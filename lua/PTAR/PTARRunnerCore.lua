-- State machine with an injected MacroQuest adapter. Times are milliseconds.
local M={}
-- Me.Heading.Degrees and /face heading use opposite numeric directions on RoF2.
function M.face_heading(stored) return (360-stored)%360 end
local function heading_error(actual,expected)
  return math.abs((actual-expected+180)%360-180)
end
local function dist(a,b)
  return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)
end
local function radius(w) return w.radius or 15 end
local function has_fall(w) return w.phases and w.phases[1]=='fall' end
local function water(w) return w.phases and #w.phases>1 end
local function xy(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local TRAVERSAL_PHASES={traverse_facing=true,traverse_approach=true,traverse_falling=true,
  water_facing=true,water_descend=true,water_cross=true,water_ascend=true}
-- TAC events (DL-013). The three values below are first guesses, not measured (Protocol section 15).
local TAC_PHASES={tac_before=true,tac_after=true,tac_assert=true}
local TAC_ANSWER_MS=5000        -- wait for an /ac status answer
local TAC_MAX_ATTEMPTS=3        -- first attempt plus 2 retries
local TAC_RETRY_SPACING_MS=1000 -- pause between attempts
local BARRIER_TIMEOUT_MS=120000 -- first guess, not measured (Protocol section 15): DL-010
local function tac_word(command) return command=='pause' and 'paused' or 'running' end

function M.new(route,io,opts)
  opts=opts or {}
  local self={route=route,io=io,status='Ready',message='Select a waypoint and Start.',selected=1,
    index=nil,last_good=nil,attempt=0,backtracked=false,forward=false,vertical=nil,door_tried=false}
  local waypoints=route.waypoints
  local function say(status,message)
    self.status=status; self.message=message; io.log(status..': '..message)
  end
  local function release()
    if self.vertical then io.vertical(self.vertical,false); self.vertical=nil end
    if self.forward then io.forward(false); self.forward=false end
  end
  local function vertical(direction)
    if self.vertical==direction then return end
    if self.vertical then io.vertical(self.vertical,false) end
    self.vertical=direction
    if direction then io.vertical(direction,true) end
  end
  local function halt()
    release(); io.nav_stop()
  end
  -- Last confirmed TAC state is tracked only to explain a paused TAC left behind (DL-013); no restore is attempted.
  local function note_tac_paused(why)
    if self.tac_known=='paused' then io.log('TAC left paused: '..why) end
  end
  local function fail(reason)
    halt(); self.index=nil; self.tac=nil
    say('Error',reason..' Use Resume (nearest valid waypoint) or Stop.')
    note_tac_paused('run ended with an Error')
  end
  -- Effective TAC state once waypoint `index` has completed: the last event in route order, before then after
  -- within a waypoint. nil means no event yet, and PTAR asserts nothing.
  local function tac_state_after(index)
    local last
    for i=1,index do
      local w=waypoints[i]
      if w then
        if w.tac_before=='pause' or w.tac_before=='run' then last=w.tac_before end
        if w.tac_after=='pause' or w.tac_after=='run' then last=w.tac_after end
      end
    end
    return last
  end
  local function tac_progress()
    local t=self.tac
    local text=string.format('Setting TAC to %s %s (attempt %d of %d)',tac_word(t.command),t.phrase,t.attempt,TAC_MAX_ATTEMPTS)
    if t.block_note then text=text..' [Start/Resume was blocked while this runs; it works again when this finishes.]' end
    say('Running',text)
  end
  -- Check-first, send, verify through the status query, bounded retries. `cont` runs when the phase ends.
  local function begin_tac(phase,command,phrase,cont,now)
    io.nav_stop()
    self.tac={command=command,phrase=phrase,cont=cont,attempt=1,sent=false,step='wait',asked_at=now,block_note=false}
    self.phase=phase
    tac_progress()
    io.tac_query()
  end
  local function tac_done(now,how)
    local t=self.tac
    io.log('TAC '..tac_word(t.command)..' '..how)
    self.tac=nil
    t.cont(now)
  end
  local function tac_unconfirmed(now,why)
    local t=self.tac
    if t.attempt<TAC_MAX_ATTEMPTS then
      io.log(string.format('TAC %s not confirmed after attempt %d of %d (%s); retrying',t.command,t.attempt,TAC_MAX_ATTEMPTS,why))
      t.step='retry_wait'; t.retry_at=now+TAC_RETRY_SPACING_MS
      return
    end
    if t.command=='pause' then
      io.log(string.format('TAC pause NOT confirmed after %d attempts (%s); proceeding without a confirmed pause',TAC_MAX_ATTEMPTS,why))
      local cont=t.cont
      self.tac=nil
      cont(now)
    else
      fail(string.format('TAC run was not confirmed after %d attempts (%s); TAC may still be paused (/ac run).',TAC_MAX_ATTEMPTS,why))
    end
  end
  -- Every send is logged with its reason, so a failed or retried command can be reconstructed from the log alone.
  local function tac_send(now,why)
    local t=self.tac
    io.log(string.format('TAC: sending /ac %s (attempt %d of %d): %s',t.command,t.attempt,TAC_MAX_ATTEMPTS,why))
    io.tac_command(t.command); t.sent=true
    t.step='wait'; t.asked_at=now; io.tac_query()
  end
  local function tac_tick(now)
    local t=self.tac
    if not t then return end
    if t.step=='retry_wait' then
      if now<t.retry_at then return end
      t.attempt=t.attempt+1; tac_progress()
      tac_send(now,'retry after an unconfirmed attempt')
      return
    end
    local state=io.tac_state()
    if state==nil then
      if now-t.asked_at<TAC_ANSWER_MS then return end
      io.log('TAC /ac status query timed out after '..TAC_ANSWER_MS..' ms')
      if not t.sent then
        tac_send(now,'the first status query got no answer, so the state is unknown')
        return
      end
      return tac_unconfirmed(now,'no answer to /ac status')
    end
    if state=='paused' or state=='running' then self.tac_known=state end
    if state==tac_word(t.command) then
      return tac_done(now,t.sent and ('confirmed on attempt '..t.attempt) or 'already set; no command needed')
    end
    if not t.sent then
      tac_send(now,'/ac status reported '..tostring(state))
      return
    end
    tac_unconfirmed(now,'/ac status reported '..tostring(state))
  end
  local function traversal_blocked()
    if self.tac and TAC_PHASES[self.phase] then
      self.tac.block_note=true
      say(self.status,string.format('Start/Resume blocked: PTAR is setting TAC to %s (attempt %d of %d). Try again when this finishes.',
        tac_word(self.tac.command),self.tac.attempt,TAC_MAX_ATTEMPTS))
      return true
    end
    if not TRAVERSAL_PHASES[self.phase] then return false end
    say(self.status,'Start/Resume blocked: still in traversal phase '..self.phase..'. Verify character position, then Stop before restarting.')
    return true
  end
  local function leg_detail(reason)
    local to=waypoints[self.index]
    local from=self.last_good and waypoints[self.last_good]
    local p=io.position()
    local source=from and string.format('#%d %s [%s] (%.1f, %.1f, %.1f)',self.last_good,from.label,from.id,from.x,from.y,from.z)
      or (p and string.format('current position (%.1f, %.1f, %.1f)',p.x,p.y,p.z) or 'current position')
    local destination=string.format('#%d %s [%s] (%.1f, %.1f, %.1f)',self.index,to.label,to.id,to.x,to.y,to.z)
    return reason..' | Leg: '..source..' -> '..destination
  end
  local function navigate(now)
    local w=waypoints[self.index]
    if io.combat() then
      self.phase='combat'; self.combat_return='nav'; self.combat_clear_at=nil
      say('Waiting for combat','Combat interrupted navigation to '..w.label..'; keeping the current waypoint and retries.')
      return
    end
    if not io.mesh() then fail('Navigation mesh is unavailable'); return end
    local p=io.position()
    if not p then fail('Character position unavailable'); return end
    if dist(p,w)<=radius(w) then
      self.phase='nav'; self.started=now; self.progress_at=now; self.best=0
      say('Running',string.format('#%d %s (%s), already within radius',self.index,w.label,w.type))
      return
    end
    if not io.path(w) then self:leg_failed('No navigable path to '..w.label,now); return end
    io.nav(w)
    self.phase='nav'; self.started=now; self.progress_at=now
    self.best=dist(p,w); self.door_tried=false
    say('Running',string.format('#%d %s (%s), attempt %d',self.index,w.label,w.type,self.attempt+1))
  end
  function self:leg_failed(reason,now)
    if io.combat() then
      local returning=self.phase=='backtrack' and 'backtrack' or 'nav'
      halt(); self.phase='combat'; self.combat_return=returning
      self.combat_clear_at=nil
      say('Waiting for combat','Combat interrupted '..reason..'; keeping the current waypoint and retries.')
      return
    end
    local detail=leg_detail(reason)
    io.log('FAILED LEG '..detail)
    halt()
    if self.attempt<2 then
      self.attempt=self.attempt+1
      io.log('Retry '..self.attempt..'/2: '..reason)
      navigate(now); return
    end
    if not self.backtracked and self.last_good and self.last_good<self.index then
      local old=self.index
      self.backtracked=true; self.phase='backtrack'; self.started=now
      local back=waypoints[self.last_good]
      if io.mesh() and io.path(back) then
        io.nav(back); say('Recovering','Returning to # '..self.last_good..' '..back.label..' before retrying # '..old)
        return
      end
    end
    local to=waypoints[self.index]
    fail(detail..' (two retries and recovery exhausted).')
  end
  local function advance(now)
    local w=waypoints[self.index]
    if w.tac_after and self.tac_after_for~=self.index then
      -- The waypoint's own action is complete; set TAC before anything else happens (DL-013).
      begin_tac('tac_after',w.tac_after,'after '..w.label,function(n) self.tac_after_for=self.index; advance(n) end,now)
      return
    end
    io.nav_stop()
    self.phase=nil
    if w.type=='traverse' then self.last_good=nil else self.last_good=self.index end
    if w.manual_handoff then
      self.index=nil; say('Manual handoff','Reached '..w.label..'. Continue the drops manually.')
      note_tac_paused('route handed off manually'); return
    end
    if w.type=='finish' or (w.type=='door' and w.door_after=='finish_open') then
      self.index=nil; say('Completed','Reached '..w.label..'.')
      note_tac_paused('route completed'); return
    end
    self.index=self.index+1
    if not waypoints[self.index] then fail('Route ended without a Finish'); return end
    self.attempt=0; self.backtracked=false
    navigate(now)
  end
  local function begin_door(now)
    local w=waypoints[self.index]
    io.nav_stop()
    self.phase='door'; self.door_since=now; self.door_poll_at=0
    self.door_click_at=nil; self.door_last_state=nil
    say('Running','Checking '..w.label..' before the next navigation leg')
  end
  local function begin_traverse(now)
    local w=waypoints[self.index]
    halt()
    io.face(w.heading)
    self.phase='traverse_facing'; self.started=now
    io.log(string.format('DROP FACE %s [%s] captured heading %.2f; verifying before moving',w.label,w.id,w.heading))
    say('Running','Facing for fall at '..w.label)
  end
  local function face_target(target)
    local bearing=io.bearing(target)
    if not bearing then fail('Cannot determine bearing to swim target'); return nil end
    io.face(bearing)
    return bearing
  end
  local function begin_water(now)
    local w=waypoints[self.index]
    local wet=io.wet()
    if has_fall(w) and wet~=true then fail('Fall settled without FeetWet at '..w.label); return end
    if wet==nil then fail('FeetWet unavailable at '..w.label); return end
    local heading=face_target(w.underwater_target); if not heading then return end
    self.phase='water_facing'; self.started=now; self.last_sample=now; self.swim_heading=heading
    say('Running','Facing underwater target at '..w.label)
  end
  local function traverse_landed(now,p)
    local w=waypoints[self.index]
    release(); self.last_good=nil -- Never backtrack across a drop.
    local descent=self.traverse_origin.z-p.z
    if descent<15 then fail(string.format('Ground drop %s stopped descending after only %.1f Z units (minimum 15)',w.label,descent)); return end
    if water(w) then
      io.log(string.format('WATER DROP LANDED %s descent %.1f Z',w.label,descent))
      begin_water(now); return
    end
    local exit=w.exit
    if dist(p,exit)<=exit.radius then advance(now); return end
    if not io.mesh() or not io.path(exit) then fail('No navigable path from ground landing to '..w.label..' exit'); return end
    io.nav(exit); self.phase='ground_exit'; self.started=now; self.progress_at=now; self.best=dist(p,exit)
    io.log(string.format('GROUND DROP LANDED %s descent %.1f Z; navigating to captured exit',w.label,descent))
    say('Running','Navigating to dry exit of '..w.label)
  end
  -- What a waypoint does once reached; a "tac_before" event runs first (DL-013), after any barrier (DL-010).
  local function dispatch_arrival(now)
    local w=waypoints[self.index]
    if w.type=='traverse' then
      if has_fall(w) then begin_traverse(now) else halt(); begin_water(now) end
    elseif w.type=='door' then begin_door(now)
    else advance(now) end
  end
  -- Runs after the barrier releases: tac_before, then the waypoint's own action (agreed arrival order, DL-010).
  local function after_barrier(now)
    local w=waypoints[self.index]
    if w.tac_before and self.tac_before_for~=self.index then
      begin_tac('tac_before',w.tac_before,'before '..w.label,function(n) self.tac_before_for=self.index; dispatch_arrival(n) end,now)
      return
    end
    dispatch_arrival(now)
  end
  -- Waypoint barrier (DL-010): every participant waits until the others still tracked have also reached this
  -- waypoint. REACHED is sent unconditionally on arrival, before the barrier is evaluated at all, so a client
  -- that later miscounts or proceeds early never withholds its own bark -- the stall scenario this rule
  -- prevents is only possible if the bark were sent on release instead.
  local function check_barrier(now)
    local w=waypoints[self.index]
    local roster=io.barrier_roster()
    local seen=io.barrier_seen(w.id)
    local missing={}
    for _,name in ipairs(roster) do if not seen[name] then missing[#missing+1]=name end end
    if #missing==0 then
      local seen_list={}; for name in pairs(seen) do seen_list[#seen_list+1]=name end; table.sort(seen_list)
      io.log(string.format('Barrier released %s: expected [%s], seen [%s]',w.id,table.concat(roster,','),table.concat(seen_list,',')))
      if w.type=='door' then io.clear_door_confirmed(w.door.id) end
      after_barrier(now)
      return
    end
    if now-self.barrier_started>=BARRIER_TIMEOUT_MS then
      io.log(string.format('Barrier TIMEOUT %s: proceeding without [%s] (expected [%s], waited %dms)',
        w.id,table.concat(missing,','),table.concat(roster,','),now-self.barrier_started))
      if w.type=='door' then io.clear_door_confirmed(w.door.id) end
      after_barrier(now)
    end
  end
  -- Just reached a waypoint (by any means: ordinary nav, already-within-radius, etc). Barrier-wait is
  -- deliberately NOT in TRAVERSAL_PHASES/TAC_PHASES: Start/Resume/Use-Nearest stay unguarded (a wait can run up
  -- to BARRIER_TIMEOUT_MS and recurs at every waypoint, unlike the brief TAC/traversal blocks), and combat here
  -- gets ordinary pause-and-resume, joining nav/backtrack/door/ground_exit -- this is real navmesh, not a gap.
  local function arrive(now)
    local w=waypoints[self.index]
    io.barrier_announce(w.id)
    self.phase='barrier_wait'; self.barrier_started=now
    say('Running','Waiting for the group at '..w.label..' ('..w.id..')')
    check_barrier(now)
  end
  -- Back on the last good waypoint: make sure TAC is in the state that waypoint's events left it (check-first).
  local function finish_backtrack(now)
    self.attempt=0
    local goal=tac_state_after(self.last_good)
    if goal then
      local back=waypoints[self.last_good]
      begin_tac('tac_assert',goal,'after returning to '..back.label,function(n) navigate(n) end,now)
      return
    end
    navigate(now)
  end
  function self:nearest()
    local p=io.position(); if not p or not io.mesh() then return nil,'Position or navigation mesh unavailable' end
    local best,closest
    for i,w in ipairs(waypoints) do
      -- Same elevation plus a valid path keeps the selection on this side of a drop.
      if math.abs(p.z-w.z)<=35 and io.path(w) then
        local d=dist(p,w)
        if not closest or d<closest then best=i; closest=d end
      end
    end
    if not best then return nil,'No reachable dry waypoint near your elevation; swim to dry ground first' end
    return best
  end
  function self:start(index,now)
    if traversal_blocked() then return end
    halt()
    if not waypoints[index] then fail('Invalid waypoint selection'); return end
    if io.zone()~=route.zone_short_name then fail('Wrong zone: expected '..route.zone_short_name); return end
    if not io.mesh() then fail('Navigation mesh is unavailable'); return end
    self.selected=index; self.index=index; self.last_good=nil; self.attempt=0; self.backtracked=false
    self.tac=nil; self.tac_before_for=nil; self.tac_after_for=nil
    io.barrier_clear() -- DL-010: a fresh run must not pass every waypoint instantly on stale barrier state
    local goal=tac_state_after(index-1)
    if goal then
      begin_tac('tac_assert',goal,'before starting at '..waypoints[index].label,function(n) navigate(n) end,now)
      return
    end
    navigate(now)
  end
  function self:start_nearest(now)
    if traversal_blocked() then return end
    local i,err=self:nearest()
    if not i then fail(err); return end
    self:start(i,now)
  end
  function self:resume(now)
    self:start_nearest(now)
  end
  -- True exactly while PTAR is setting TAC (DL-013), i.e. while Start/Resume are blocked; the UI reads it.
  -- Not derived from `phase`, which keeps its last value after an Error.
  function self:tac_busy() return self.tac~=nil end
  -- True exactly while a traversal phase blocks Start/Resume/Use-Nearest (DL-001). Live-recomputed from `phase`
  -- every call, not from `message` -- the message-based block note was found live (2026-09-28) to get silently
  -- overwritten within seconds by the traversal's own routine progress narration, making it easy to miss.
  function self:traversal_blocking() return TRAVERSAL_PHASES[self.phase]==true end
  -- Whether a PTAR:HERE heartbeat should be sent right now (DL-010): only while actively trying to complete the
  -- route, so an errored, paused, stopped, dead or completed client drops out of everyone's roster quickly
  -- instead of holding a barrier open. The rule lives here, not in the adapter, so it is unit-tested.
  function self:heartbeat_active() return self.status=='Running' or self.status=='Recovering' or self.status=='Waiting for combat' end
  function self:pause()
    halt(); self.index=nil; self.tac=nil; say('Paused','Paused. Resume selects the nearest reachable dry waypoint.')
    note_tac_paused('run paused by the user')
  end
  function self:stop()
    halt(); self.index=nil; self.selected=1; self.last_good=nil; self.phase=nil; self.tac=nil
    say('Ready','Stopped. Start defaults to the first waypoint.')
    note_tac_paused('run stopped by the user')
  end
  function self:tick(now)
    if self.status~='Running' and self.status~='Recovering' and self.status~='Waiting for combat' then return end
    if self.phase=='door_zone' then
      local zone=io.zone()
      if zone and zone~=route.zone_short_name and io.position() then
        local door=waypoints[self.index]
        halt(); self.index=nil
        say('Completed','Zoned through '..door.label..' to '..zone..'.')
        note_tac_paused('route completed')
      elseif now-self.door_click_at>45000 then
        fail('Did not zone after clicking '..waypoints[self.index].label)
      end
      return
    end
    if io.zone()~=route.zone_short_name then fail('Zone changed'); return end
    local p=io.position(); if not p then fail('Character position unavailable'); return end
    local w=waypoints[self.index]
    if self.phase=='combat' then
      if io.combat() then
        if self.combat_clear_at then io.log('Combat resumed during clear window; waiting again') end
        self.combat_clear_at=nil; return
      end
      if not self.combat_clear_at then
        self.combat_clear_at=now
        io.log('Combat cleared; waiting 2000 ms before resuming '..w.label)
      end
      if now-self.combat_clear_at<2000 then return end
      local returning=self.combat_return
      self.combat_clear_at=nil; self.combat_return=nil
      io.log('Combat clear for 2000 ms; resuming '..returning..' toward '..w.label)
      if returning=='backtrack' then
        local back=waypoints[self.last_good]
        if dist(p,back)<=radius(back) then finish_backtrack(now)
        elseif not io.mesh() or not io.path(back) then fail('Could not return to previous known good waypoint')
        else io.nav(back); self.phase='backtrack'; self.started=now
          say('Recovering','Returning to # '..self.last_good..' '..back.label..' after combat') end
      elseif returning=='barrier_wait' then
        self.phase='barrier_wait'; check_barrier(now)
      elseif returning=='ground_exit' then
        local exit=w.exit
        if dist(p,exit)<=exit.radius then
          io.nav_stop(); self.attempt=0; self.backtracked=false; advance(now)
        elseif not io.mesh() or not io.path(exit) then fail('No navigable path from ground landing to '..w.label..' exit')
        else io.nav(exit); self.phase='ground_exit'; self.started=now; self.progress_at=now; self.best=dist(p,exit)
          say('Running','Navigating to dry exit of '..w.label..' after combat') end
      else navigate(now) end
      return
    end
    if TAC_PHASES[self.phase] then
      io.combat() -- combat is ignored while PTAR sets TAC (DL-013): the character is stationary and about to change TAC anyway
      tac_tick(now)
      return
    end
    if io.combat() and (self.phase=='nav' or self.phase=='backtrack' or self.phase=='door' or self.phase=='ground_exit' or self.phase=='barrier_wait') then
      local returning=self.phase=='backtrack' and 'backtrack' or (self.phase=='ground_exit' and 'ground_exit' or
        (self.phase=='barrier_wait' and 'barrier_wait' or 'nav'))
      halt(); self.phase='combat'; self.combat_return=returning; self.combat_clear_at=nil
      say('Waiting for combat','Combat interrupted '..w.label..'; keeping the current waypoint and retries.')
      return
    end
    if self.phase=='barrier_wait' then check_barrier(now); return end
    if self.phase=='backtrack' then
      local back=waypoints[self.last_good]
      if dist(p,back)<=radius(back) then
        io.nav_stop(); finish_backtrack(now)
      elseif now-self.started>45000 or (now-self.started>3000 and not io.nav_active()) then
        fail('Could not return to previous known good waypoint')
      end
      return
    end
    if self.phase=='nav' then
      if dist(p,w)<=radius(w) then
        arrive(now)
        return
      end
      local d=dist(p,w)
      if d<self.best-3 then self.best=d; self.progress_at=now end
      if now-self.progress_at>12000 and not self.door_tried and self.index>1 then
        local previous=waypoints[self.index-1]
        if previous.type=='door' and dist(p,previous)<50 then
          self.door_tried=true
          local result=io.door(previous)
          io.log('Door stall fallback '..previous.label..': '..tostring(result))
          if result=='clicked' then self.progress_at=now; return end
        end
      end
      if now-self.progress_at>16000 or now-self.started>90000 or (now-self.started>3000 and not io.nav_active()) then
        local reason=not io.mesh() and 'Navigation mesh became unavailable' or
          (not io.path(w) and 'No navigable path to '..w.label or 'Navigation stalled at '..w.label)
        self:leg_failed(reason,now)
      end
      return
    end
    if self.phase=='traverse_facing' then
      io.combat() -- combat is ignored during traversal phases, not acted on (DL-006): TAC cannot reach a navmesh gap either way
      local actual=io.heading()
      if actual and heading_error(actual,w.heading)<=5 then
        self.traverse_origin={x=p.x,y=p.y,z=p.z}; self.last_z=p.z; self.last_sample=now
        io.forward(true); self.forward=true; self.phase='traverse_approach'; self.started=now
        io.log(string.format('FALL TRAVERSE %s [%s] heading %.2f verified %.2f origin %.2f,%.2f,%.2f; max approach %.1f units / 7000 ms',
          w.label,w.id,w.heading,actual,p.x,p.y,p.z,math.max(35,dist(w,w.ledge)+45)))
        say('Running','Ground drop traverse from '..w.label..'; watching for the fall')
      elseif now-self.started>=1000 then
        fail(string.format('Ground drop heading could not be verified at %s (captured %.2f, actual %s)',
          w.label,w.heading,actual and string.format('%.2f',actual) or 'unavailable'))
      end
      return
    end
    if self.phase=='water_facing' or self.phase=='water_descend' or self.phase=='water_cross' or self.phase=='water_ascend' then
      io.combat() -- combat is ignored during traversal phases, not acted on (DL-006): stopping here guarantees drowning/mob damage with no way to fight back
      local target=w.underwater_target
      local exit=w.exit
      if not target or not exit then fail('Water traversal target or exit missing'); return end
      if self.phase=='water_facing' then
        local actual=io.heading()
        if actual and heading_error(actual,self.swim_heading)<=5 then
          io.forward(true); self.forward=true; vertical('down')
          self.phase='water_descend'; self.started=now
          say('Running','Descending under water toward '..target.x..', '..target.y)
        elseif now-self.started>1500 then fail('Could not verify swim heading at '..w.label) end
        return
      end
      if self.phase=='water_descend' then
        local feet,head=io.wet()
        if feet==nil or head==nil then fail('Water state unavailable while descending'); return end
        if head then
          if not feet then fail('HeadWet without FeetWet at '..w.label); return end
        end
        -- Reach the captured swim depth before crossing. A small lead allows
        -- the level command to arrive before the character passes the target.
        if head and p.z<=target.z+math.min(2,target.radius/2) then
          vertical(nil); self.phase='water_cross'; self.started=now
          self.best=dist(p,target); self.progress_at=now
          say('Running','Underwater crossing toward '..w.label..' target')
        elseif now-self.started>8000 then
          fail((head and 'Target depth not reached' or 'HeadWet did not become true while descending')..' at '..w.label)
        end
        return
      end
      if self.phase=='water_cross' then
        local distance=dist(p,target)
        if distance<=target.radius then
          local bearing=face_target(exit); if not bearing then return end
          self.swim_heading=bearing; self.phase='water_ascend'; self.started=now
          self.best=dist(p,exit); self.progress_at=now
          vertical('up'); say('Running','Ascending toward dry exit of '..w.label)
          return
        end
        -- Correct depth overshoot while moving forward so the 3D target can
        -- still be reached if the dive crosses the intended Z between ticks.
        local depth_error=p.z-target.z
        if depth_error>target.radius/2 then vertical('down')
        elseif depth_error< -target.radius/2 then vertical('up')
        else vertical(nil) end
        if distance<self.best-1 then self.best=distance; self.progress_at=now end
        if now-self.progress_at>7000 or now-self.started>45000 then fail('Underwater crossing stalled at '..w.label); return end
        if now-self.last_sample>=300 then
          self.last_sample=now
          local bearing=io.bearing(target)
          if not bearing then fail('Cannot read underwater target bearing'); return end
          if not io.heading() or heading_error(io.heading(),bearing)>8 then io.face(bearing) end
        end
        return
      end
      local feet=io.wet()
      if feet==nil then fail('FeetWet unavailable while ascending'); return end
      local distance=dist(p,exit)
      if not feet and distance<=exit.radius then
        release(); self.last_good=nil
        io.log('WATER EXIT VERIFIED '..w.label..' distance '..string.format('%.1f',distance))
        self.attempt=0; self.backtracked=false
        advance(now); return
      end
      if distance<self.best-1 then self.best=distance; self.progress_at=now end
      if now-self.progress_at>7000 or now-self.started>20000 then fail('Water exit stalled at '..w.label); return end
      if now-self.last_sample>=300 then
        self.last_sample=now
        local bearing=io.bearing(exit)
        if not bearing then fail('Cannot read dry exit bearing'); return end
        if not io.heading() or heading_error(io.heading(),bearing)>8 then io.face(bearing) end
      end
      return
    end
    if self.phase=='traverse_approach' or self.phase=='traverse_falling' then
      io.combat() -- combat is ignored during traversal phases, not acted on (DL-006): TAC cannot reach a navmesh gap either way
      if self.phase=='traverse_approach' then
        local actual=io.heading()
        if not actual or heading_error(actual,w.heading)>15 then
          fail(string.format('Ground drop heading drifted at %s (captured %.2f, actual %s)',
            w.label,w.heading,actual and string.format('%.2f',actual) or 'unavailable')); return
        end
      end
      local elapsed=now-self.last_sample
      if elapsed>=100 then
        local speed=(self.last_z-p.z)*1000/elapsed
        self.last_z=p.z; self.last_sample=now
        if self.phase=='traverse_approach' and speed>15 then
          release(); self.phase='traverse_falling'; self.started=now; self.slow_since=nil
          self.last_good=nil
          io.log(string.format('GROUND DROP FALL START %s at X %.2f Y %.2f Z %.2f; descent speed %.1f Z/s',
            w.label,p.x,p.y,p.z,speed))
        elseif self.phase=='traverse_falling' then
          if math.abs(speed)<4 then self.slow_since=self.slow_since or now else self.slow_since=nil end
          if self.slow_since and now-self.slow_since>=750 then traverse_landed(now,p); return end
        end
      end
      local approach_limit=math.max(35,dist(w,w.ledge)+45)
      if self.phase=='traverse_approach' and dist(p,self.traverse_origin)>approach_limit then
        fail(string.format('Fall approach passed %.1f-unit limit at %s',approach_limit,w.label)); return
      end
      if self.phase=='traverse_approach' and now-self.started>7000 then fail('Fall did not begin within 7000 ms at '..w.label)
      elseif self.phase=='traverse_falling' and now-self.started>20000 then fail('Ground drop did not settle within 20000 ms at '..w.label) end
      return
    end
    if self.phase=='door' then
      if now<self.door_poll_at then return end
      self.door_poll_at=now+300
      local state,detail=io.door_state(w)
      local state_text=state==nil and ('unavailable: '..tostring(detail)) or tostring(state)
      if state_text~=self.door_last_state then
        io.log(string.format('Door %s [%s]: state %s, attempt %d, elapsed %d ms',w.label,
          tostring(w.door and w.door.id),state_text,self.attempt+1,now-self.door_since))
        self.door_last_state=state_text
      end
      if w.door_after=='finish_zone' then
        if state==nil then
          if now-self.door_since>=2000 then fail('Cannot verify door target before zoning at '..w.label..': '..tostring(detail)) end
          return
        end
        local result=io.door(w,true)
        if result=='clicked' then
          self.door_click_at=now; self.phase='door_zone'
          say('Running','Clicked '..w.label..'; waiting for zone load')
        else
          fail('Could not click zoning door '..w.label..': '..tostring(result))
        end
        return
      end
      if state==true or io.door_confirmed(w.door.id) then
        if state==true and io.door_role()=='primary' then io.announce_door_open(w.door.id) end
        advance(now); return
      end
      if io.door_role()=='secondary' then
        if now-self.door_since>=8000 then self:leg_failed('No door-open confirmation received for '..w.label,now) end
        return
      end
      if state==nil then
        if now-self.door_since>=2000 then
          io.log('Door state unavailable; continuing with the existing Nav and stall fallback: '..w.label)
          advance(now)
        end
        return
      end
      if not self.door_click_at then
        local result=io.door(w)
        if result=='clicked' then
          self.door_click_at=now
          io.log('Clicked closed door '..w.label..'; awaiting fully open state')
        elseif result=='open' then
          io.log('Door opened before click: '..w.label)
        else
          io.log('Door click unavailable: '..w.label)
          self:leg_failed('Could not click '..w.label,now)
        end
      elseif now-self.door_click_at>=8000 then
        self:leg_failed('Door did not fully open: '..w.label,now)
      end
      return
    end
    if self.phase=='ground_exit' then
      local exit=w.exit
      if dist(p,exit)<=exit.radius then
        io.nav_stop(); self.attempt=0; self.backtracked=false; advance(now); return
      end
      local distance=dist(p,exit)
      if distance<self.best-3 then self.best=distance; self.progress_at=now end
      if now-self.progress_at>16000 or now-self.started>90000 or (now-self.started>3000 and not io.nav_active()) then
        fail('Navigation stalled between ground landing and '..w.label..' exit')
      end
      return
    end
  end
  return self
end
return M
