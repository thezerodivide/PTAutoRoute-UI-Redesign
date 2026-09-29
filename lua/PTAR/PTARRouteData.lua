-- Sleeper's Tomb Route Capture: data, validation and persistence (no MQ dependency).
local M = {}
M.FORMAT_VERSION = 3
local TYPES = { normal=true, door=true, traverse=true, finish=true }
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function filled(s) return type(s)=='string' and s:match('%S') ~= nil end
local function exists(path) local f=io.open(path,'rb'); if f then f:close(); return true end; return false end
local function copy(source,dest)
  local a,e=io.open(source,'rb'); if not a then return nil,e end
  local b,err=io.open(dest,'wb'); if not b then a:close(); return nil,err end
  local data=a:read('*a'); local ok,werr=b:write(data); a:close()
  if not ok then b:close(); os.remove(dest); return nil,werr end
  local closed,cerr=b:close(); if not closed then os.remove(dest); return nil,cerr end
  return true
end
M.exists=exists

-- Files are Lua literals loaded with no globals. Reject executable constructs before executing
-- the literal to avoid arbitrary computation in a hand-edited route file.
local function literal_only(source)
  local i,n=1,#source
  local function skip()
    while i<=n do
      local c=source:sub(i,i)
      if c:match('%s') then i=i+1
      elseif source:sub(i,i+1)=='--' then
        if source:sub(i+2,i+3)=='[[' then
          local endpos=source:find(']]',i+4,true); if not endpos then error('unterminated comment') end; i=endpos+2
        else local endpos=source:find('\n',i+2,true); i=endpos and endpos+1 or n+1 end
      else break end
    end
  end
  local function token()
    skip(); if i>n then return nil end
    local c=source:sub(i,i)
    if c=='"' or c=="'" then
      local start=i; i=i+1
      while i<=n do
        local q=source:sub(i,i)
        if q=='\\' then i=i+2
        elseif q==c then i=i+1; return 'string',source:sub(start,i-1)
        else i=i+1 end
      end
      error('unterminated string')
    end
    if c:match('[%a_]') then
      local start=i; repeat i=i+1 until i>n or not source:sub(i,i):match('[%w_]')
      return 'word',source:sub(start,i-1)
    end
    if c:match('[%d]') or (c=='.' and source:sub(i+1,i+1):match('%d')) then
      local start=i; local tail=source:sub(i); local number=tail:match('^0[xX][%da-fA-F]+') or tail:match('^%d+%.?%d*[eE][%+%-]?%d+') or tail:match('^%d+%.?%d*') or tail:match('^%.%d+[eE][%+%-]?%d+') or tail:match('^%.%d+')
      if not number then error('bad numeric literal') end
      i=i+#number; return 'number',source:sub(start,i-1)
    end
    i=i+1; return c,c
  end
  local toks={}; while true do local kind,value=token(); if not kind then break end; toks[#toks+1]={kind,value} end
  local p=1
  local function peek() return toks[p] and toks[p][1] end
  local function take(k) if peek()~=k then error('expected '..k..' at token '..p) end; p=p+1 end
  local value
  value=function(depth)
    if depth>64 then error('route nesting too deep') end
    local k=peek()
    if k=='{' then
      take('{')
      while peek() and peek()~='}' do
        if peek()=='[' then take('['); value(depth+1); take(']'); take('='); value(depth+1)
        elseif peek()=='word' and toks[p+1] and toks[p+1][1]=='=' then p=p+2; value(depth+1)
        else value(depth+1) end
        if peek()==',' or peek()==';' then p=p+1 elseif peek()~='}' then error('expected separator') end
      end
      take('}')
    elseif k=='-' then take('-'); take('number')
    elseif k=='number' or k=='string' then p=p+1
    elseif k=='word' then
      local word=toks[p][2]; if word~='true' and word~='false' then error('non-data identifier '..word) end; p=p+1
    else error('expected data literal at token '..p) end
  end
  if not toks[p] or toks[p][2]~='return' then error('route must return a table') end; p=p+1
  value(0); if p<=#toks then error('trailing executable content') end
end
local function data_tree(t,seen,depth)
  if depth>64 then return nil,'data nesting too deep' end
  local ty=type(t)
  if ty=='string' or ty=='boolean' then return true end
  if ty=='number' then if finite(t) then return true end; return nil,'non-finite number' end
  if ty~='table' then return nil,'unsupported data type '..ty end
  if getmetatable(t) then return nil,'metatables are not route data' end
  if seen[t] then return nil,'shared/cyclic table is not route data' end
  seen[t]=true
  for k,v in pairs(t) do
    if type(k)~='string' and (not finite(k) or k%1~=0) then return nil,'unsupported table key' end
    local ok,e=data_tree(v,seen,depth+1); if not ok then return nil,e end
  end
  seen[t]=nil; return true
end
local function read(path)
  local file,e=io.open(path,'rb'); if not file then return nil,e end
  local text=file:read('*a'); file:close()
  if #text>4*1024*1024 then return nil,'route file exceeds 4 MiB' end
  local allowed,err=pcall(literal_only,text); if not allowed then return nil,'non-data route: '..tostring(err) end
  local chunk,ce
  if setfenv and loadstring then
    chunk,ce=loadstring(text,'@'..path)
    if chunk then setfenv(chunk,{}) end
  else
    chunk,ce=load(text,'@'..path,'t',{})
  end
  if not chunk then return nil,ce end
  local ok,value=pcall(chunk); if not ok then return nil,value end
  local good,why=data_tree(value,{},0); if not good then return nil,why end
  return value
end
M.read=read

function M.validate(route)
  local errors,warnings={},{}
  local function hard(s) errors[#errors+1]=s end
  local function warn(s) warnings[#warnings+1]=s end
  if type(route)~='table' then hard('Route is not a table'); return errors,warnings end
  if type(route.format_version)~='number' or route.format_version%1~=0 then hard('Invalid format_version')
  elseif route.format_version>M.FORMAT_VERSION then hard('Unsupported newer format_version '..route.format_version)
  elseif route.format_version~=M.FORMAT_VERSION then hard('Unsupported format_version '..route.format_version) end
  if not finite(route.next_id) or route.next_id%1~=0 or route.next_id<1 then hard('Invalid next_id') end
  if not filled(route.route_name) then hard('Route name is required') end
  if not filled(route.zone_short_name) then hard('Zone short name is required') end
  if route.description~=nil and type(route.description)~='string' then hard('Invalid description') end
  if type(route.waypoints)~='table' then hard('Waypoints must be an array'); return errors,warnings end
  local count,max,ids,finish=0,0,{},0
  for k in pairs(route.waypoints) do
    if type(k)~='number' or k%1~=0 or k<1 then hard('Waypoint array has an invalid key') else if k>count then count=k end end
  end
  for i=1,count do
    local w=route.waypoints[i]
    if type(w)~='table' then hard('Waypoint '..i..' is missing or malformed')
    else
      local prefix='Waypoint '..i..': '
      local num=type(w.id)=='string' and w.id:match('^wp_(%d+)$')
      if not num then hard(prefix..'invalid ID') else
        local idn=tonumber(num); if ids[w.id] then hard(prefix..'duplicate ID '..w.id) end
        ids[w.id]=true; max=math.max(max,idn)
      end
      if not filled(w.label) then hard(prefix..'label is required') end
      if not TYPES[w.type] then hard(prefix..'invalid type') end
      for _,field in ipairs({'x','y','z','heading'}) do if not finite(w[field]) then hard(prefix..'invalid '..field) end end
      if w.radius~=nil and (not finite(w.radius) or w.radius<=0) then hard(prefix..'invalid radius') end
      if w.type=='traverse' then
        if not finite(w.radius) or w.radius>5 or w.radius<=0 then hard(prefix..'Traversal approach requires radius from 0 to 5') end
        local phases=w.phases
        local signature=''
        if type(phases)=='table' then
          local pieces={}; for j=1,#phases do if type(phases[j])~='string' then pieces={}; break end; pieces[j]=phases[j] end
          signature=table.concat(pieces,',')
        end
        local ground=signature=='fall'
        local water=signature=='fall,descend,cross,ascend' or signature=='descend,cross,ascend'
        if not ground and not water then hard(prefix..'unsupported traversal phases') end
        if type(phases)=='table' then
          local expected=ground and 1 or water and (phases[1]=='fall' and 4 or 3) or -1
          local n=0; for k in pairs(phases) do if type(k)~='number' or k%1~=0 or k<1 then n=-100; break end; n=n+1 end
          if n~=expected then hard(prefix..'invalid phase array') end
        end
        local fall=ground or signature=='fall,descend,cross,ascend'
        local ledge=w.ledge
        if fall then
          if not finite(w.heading) then hard(prefix..'Fall requires departure heading') end
          if type(ledge)~='table' or not finite(ledge.x) or not finite(ledge.y) or not finite(ledge.z) then
            hard(prefix..'Fall requires ledge X/Y/Z') end
        elseif ledge~=nil then hard(prefix..'Water crossing without Fall cannot have a ledge') end
        if water then
          local t=w.underwater_target
          if type(t)~='table' or not finite(t.x) or not finite(t.y) or not finite(t.z) or
              not finite(t.radius) or t.radius<=0 then hard(prefix..'water crossing requires underwater target X/Y/Z and positive radius') end
        elseif w.underwater_target~=nil then hard(prefix..'ground traverse cannot have an underwater target') end
        local exit=w.exit
        if type(exit)~='table' or not finite(exit.x) or not finite(exit.y) or not finite(exit.z) or
            not finite(exit.radius) or exit.radius<=0 then hard(prefix..'Traversal requires exit X/Y/Z and positive radius') end
      end
      if w.manual_handoff~=nil and (type(w.manual_handoff)~='boolean' or w.type~='normal') then hard(prefix..'manual_handoff requires a normal waypoint') end
      if w.door_after~=nil then
        if w.type~='door' or (w.door_after~='continue' and w.door_after~='finish_open' and w.door_after~='finish_zone') then
          hard(prefix..'door_after requires a door and a supported outcome')
        elseif w.door_after~='continue' then finish=finish+1 end
      end
      for _,field in ipairs({'tac_before','tac_after'}) do
        local v=w[field]
        if v~=nil and v~='pause' and v~='run' then hard(prefix..field..' must be "pause" or "run"') end
      end
      if w.notes~=nil and type(w.notes)~='string' then hard(prefix..'invalid notes') end
      if w.type=='finish' then finish=finish+1; if not finite(w.radius) or w.radius<=0 then hard(prefix..'Finish requires an explicit positive radius') end end
      if w.drop_id~=nil or w.landing~=nil then hard(prefix..'Drop Pre/Post metadata is no longer supported') end
      if w.type=='door' then
        local d=w.door
        if type(d)~='table' or not finite(d.id) or d.id%1~=0 or not filled(d.name) or not finite(d.x) or not finite(d.y) or not finite(d.z) then
          hard(prefix..'Door requires target ID, name and X/Y/Z') end
      end
      if i>1 and type(route.waypoints[i-1])=='table' then
        local prev=route.waypoints[i-1]
        if finite(w.x) and finite(w.y) and finite(w.z) and finite(prev.x) and finite(prev.y) and finite(prev.z) then
          local dist=math.sqrt((w.x-prev.x)^2+(w.y-prev.y)^2+(w.z-prev.z)^2)
          if dist>400 then warn(prefix..string.format('large spacing (%.1f)',dist)) end
        end
      end
    end
  end
  if finite(route.next_id) and route.next_id<=max then hard('next_id must exceed all allocated waypoint IDs') end
  -- Final effective TAC state (DL-013): the last event in route order, "before" then "after" within a waypoint.
  local last_tac
  for i=1,count do
    local w=route.waypoints[i]
    if type(w)=='table' then
      if w.tac_before=='pause' or w.tac_before=='run' then last_tac=w.tac_before end
      if w.tac_after=='pause' or w.tac_after=='run' then last_tac=w.tac_after end
    end
  end
  if last_tac=='pause' then warn('Route ends with TAC paused (no later "run" event)') end
  if finish==0 then warn('No Finish waypoint yet') elseif finish>1 then warn('Multiple Finish waypoints') end
  if finish==1 and type(route.waypoints[count])=='table' and route.waypoints[count].type~='finish' and
      route.waypoints[count].door_after~='finish_open' and route.waypoints[count].door_after~='finish_zone' then warn('Finish is not last') end
  local good,why=data_tree(route,{},0); if not good then hard(why) end
  return errors,warnings
end
local known_route={'format_version','next_id','route_name','zone_short_name','description','waypoints'}
local known_wp={'id','label','type','x','y','z','heading','radius','door_after','phases','ledge','underwater_target','exit','notes','manual_handoff','tac_before','tac_after','door','segment'}
local known_door={'id','name','x','y','z'}
local function quote(s) return string.format('%q',s) end
local function keys(t,priority)
  local list,done={},{}
  for _,k in ipairs(priority or {}) do if t[k]~=nil then list[#list+1]=k; done[k]=true end end
  local extra={}; for k in pairs(t) do if not done[k] then extra[#extra+1]=k end end
  table.sort(extra,function(a,b) if type(a)==type(b) then return a<b end; return type(a)<type(b) end)
  for _,k in ipairs(extra) do list[#list+1]=k end
  return list
end
local function value(v,depth,priority,field)
  local t=type(v)
  if t=='string' then return quote(v) end
  if t=='number' then
    if not finite(v) then error('non-finite number') end
    if (priority=='waypoint' and (field=='x' or field=='y' or field=='z' or field=='heading')) or
       (priority=='door' and (field=='x' or field=='y' or field=='z')) then return string.format('%.3f',v) end
    return string.format('%.17g',v)
  end
  if t=='boolean' then return tostring(v) end
  if t~='table' then error('unsupported data type '..t) end
  local pad=string.rep('    ',depth); local out={'{'}
  local array_count=0; while rawget(v,array_count+1)~=nil do array_count=array_count+1 end
  for i=1,array_count do
    out[#out+1]='\n'..pad..'    '..value(v[i],depth+1,priority=='waypoints' and 'waypoint' or nil)..','
  end
  for _,k in ipairs(keys(v,priority=='route' and known_route or priority=='waypoint' and known_wp or priority=='door' and known_door or nil)) do
    if not (type(k)=='number' and k>=1 and k<=array_count and k%1==0) then
      local key=type(k)=='string' and k:match('^[%a_][%w_]*$') and k or '['..value(k,0)..']'
      local nested=k=='waypoints' and 'waypoints' or k=='door' and 'door' or
        (k=='underwater_target' or k=='ledge' or k=='exit') and 'waypoint' or nil
      out[#out+1]='\n'..pad..'    '..key..' = '..value(v[k],depth+1,nested or (type(v[k])~='table' and priority or nil),k)..','
    end
  end
  if #out>1 then out[#out+1]='\n'..pad end
  out[#out+1]='}'; return table.concat(out)
end
function M.serialize(route)
  local errs=M.validate(route); if #errs>0 then return nil,table.concat(errs,'; ') end
  -- Explicitly format waypoint/door known fields while keeping all other data.
  local function normalize(t)
    -- The writer below selects known fields by table identity via a special walk.
    return t
  end
  return '-- MacroQuest coordinates: x=Me.X, y=Me.Y, z=Me.Z. /nav locyxz uses y x z.\nreturn '..value(normalize(route),0,'route')..'\n'
end
-- Position and heading are rounded at capture/edit time, preserving exact round trips thereafter.
function M.round_position(p)
  local r={}; for _,k in ipairs({'x','y','z','heading'}) do
    if not finite(p[k]) then return nil,'Invalid '..k end
    r[k]=tonumber(string.format('%.3f',p[k]))
  end; return r
end
function M.new(name,zone,description)
  return {format_version=M.FORMAT_VERSION,next_id=1,route_name=name,zone_short_name=zone,description=description or '',waypoints={}}
end
function M.create(route,where,index,fields,pos,now,last)
  local rounded,e=M.round_position(pos); if not rounded then return nil,e end
  local errors=M.validate(route); if #errors>0 then return nil,table.concat(errors,'; ') end
  if where~='append' and (type(index)~='number' or not route.waypoints[index]) then return nil,'Select an existing waypoint for insertion' end
  if type(fields)~='table' then return nil,'Missing fields' end
  if last and now and now-last.time<750 then
    local d=math.sqrt((rounded.x-last.x)^2+(rounded.y-last.y)^2+(rounded.z-last.z)^2)
    if d<1.0 then return nil,'Duplicate capture ignored (same position within 750 ms)' end
  end
  local wp={id=string.format('wp_%03d',route.next_id),label=fields.label,type=fields.type,
    x=rounded.x,y=rounded.y,z=rounded.z,heading=rounded.heading,notes=fields.notes or '',radius=fields.radius}
  if fields.type=='door' then wp.door=fields.door; wp.door_after=fields.door_after~='continue' and fields.door_after or nil end
  if fields.type=='normal' and fields.manual_handoff then wp.manual_handoff=true end
  if fields.tac_before~=nil then wp.tac_before=fields.tac_before end
  if fields.tac_after~=nil then wp.tac_after=fields.tac_after end
  if fields.type=='traverse' then
    wp.phases=fields.phases; wp.ledge=fields.ledge; wp.underwater_target=fields.underwater_target; wp.exit=fields.exit
  end
  local index_to_add=where=='append' and (#route.waypoints+1) or (where=='before' and index or index+1)
  table.insert(route.waypoints,index_to_add,wp); route.next_id=route.next_id+1
  return wp,index_to_add
end
function M.remove(route,id)
  for i,w in ipairs(route.waypoints) do if w.id==id then table.remove(route.waypoints,i); return true end end
  return nil,'Waypoint not found'
end
function M.move(route,id,direction)
  for i,w in ipairs(route.waypoints) do if w.id==id then
    local j=i+direction; if j<1 or j>#route.waypoints then return nil,'Already at end' end
    route.waypoints[i],route.waypoints[j]=route.waypoints[j],route.waypoints[i]; return j
  end end; return nil,'Waypoint not found'
end
function M.replace_position(w,p)
  local r,e=M.round_position(p); if not r then return nil,e end
  for k,v in pairs(r) do w[k]=v end; return true
end
function M.distance(a,b)
  if not a or not b or not finite(a.x) or not finite(a.y) or not finite(a.z) or not finite(b.x) or not finite(b.y) or not finite(b.z) then return nil end
  return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)
end
function M.save(route,path)
  local serialized,e=M.serialize(route); if not serialized then return nil,e end
  local tmp,bak=path..'.tmp',path..'.bak'
  local f,fe=io.open(tmp,'wb'); if not f then return nil,fe end
  local wrote,we=f:write(serialized); local closed,ce=f:close()
  if not wrote or not closed then return nil,we or ce end
  local test,te=read(tmp); if not test then return nil,'Temporary route failed reload: '..te end
  local errs=M.validate(test); if #errs>0 then return nil,'Temporary route failed validation: '..table.concat(errs,'; ') end
  if M.serialize(test)~=serialized then return nil,'Temporary route failed round-trip verification' end
  if exists(path) then
    local prior,pe=read(path); if not prior then return nil,'Current main file invalid: '..pe..' (use recovery)' end
    local bad=M.validate(prior); if #bad>0 then return nil,'Current main file invalid: '..table.concat(bad,'; ') end
    local ok,err=copy(path,bak..'.tmp'); if not ok then return nil,'Backup copy failed: '..tostring(err) end
    local backup=read(bak..'.tmp'); if not backup then return nil,'Backup verification failed' end
    os.remove(bak); local renamed,re=os.rename(bak..'.tmp',bak)
    if not renamed then return nil,'Backup promotion failed: '..tostring(re) end
    -- Windows does not replace an open/existing destination with os.rename.
    local removed,remerr=os.remove(path); if not removed then return nil,'Could not replace main: '..tostring(remerr) end
  end
  local promoted,perr=os.rename(tmp,path)
  if not promoted then return nil,'Main promotion failed (recover .tmp or .bak): '..tostring(perr) end
  return true
end
function M.recover(path)
  local function good(file)
    if not exists(file) then return nil,'missing' end
    local r,e=read(file); if not r then return nil,e end
    local errors=M.validate(r); if #errors>0 then return nil,table.concat(errors,'; ') end
    return r
  end
  local main,me=good(path)
  if main then return main,nil end -- A valid main beats any leftover .tmp.
  local tmp,te=good(path..'.tmp'); local bak,be=good(path..'.bak')
  if tmp then
    local ok,e=os.rename(path..'.tmp',path)
    if not ok then os.remove(path); ok,e=os.rename(path..'.tmp',path) end
    if ok then return tmp,'Recovered validated temporary route ('..tostring(me)..')' end
    return tmp,'Temporary route valid but could not promote: '..tostring(e)
  end
  if bak then
    local ok,e=copy(path..'.bak',path)
    if ok then return bak,'Recovered validated backup ('..tostring(me)..')' end
    return bak,'Backup valid but could not restore: '..tostring(e)
  end
  return nil,'No valid route: main='..tostring(me)..', tmp='..tostring(te)..', bak='..tostring(be)
end
return M
