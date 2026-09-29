-- Combat signals kept separate so XTarget decisions can be tested without MQ.
local M={}
local combat_target_types={
  ['Auto Hater']=true, ['Pet Target']=true, ['Mercenary Target']=true,
  ["Target's Target"]=true, ["Group Tank's Target"]=true,
  ['Group Assist Target']=true, ['Group Puller Target']=true,
  ['Raid Assist 1 Target']=true, ['Raid Assist 2 Target']=true,
  ['Raid Assist 3 Target']=true,
}
local function read(fn)
  local ok,value=pcall(fn)
  return ok and value or nil
end
function M.read(mq)
  local me=mq.TLO.Me
  local me_combat=read(function() return me.Combat() end)==true
  local xt_haters=tonumber(read(function() return me.XTHaterCount() end))
  local slots=tonumber(read(function() return me.XTargetSlots() end))
  local entries={}
  local active_targets=0
  if slots and slots>=0 then
    for i=1,math.min(slots,30) do
      local xt=read(function() return me.XTarget(i) end)
      if xt then
        local id=tonumber(read(function() return xt.ID() end))
        local kind=read(function() return xt.TargetType() end)
        if id and id>0 then
          local spawn=read(function() return mq.TLO.Spawn(id) end)
          local spawn_type=spawn and read(function() return spawn.Type() end) or nil
          local hp=spawn and tonumber(read(function() return spawn.PctHPs() end)) or nil
          local blocking=combat_target_types[kind]==true and spawn_type=='NPC' and hp and hp>0 or false
          if blocking then active_targets=active_targets+1 end
          entries[#entries+1]=string.format('%d:%d:%s:%s:hp=%s:%s',i,id,
            tostring(kind),tostring(spawn_type),tostring(hp),blocking and 'active' or 'ignored')
        end
      end
    end
  end
  return {me_combat=me_combat,xt_haters=xt_haters,slots=slots,
    active_targets=active_targets,entries=entries,
    active=me_combat or (xt_haters or 0)>0 or active_targets>0}
end
return M
