-- Portable route index. Lua has no standard directory enumeration API.
local data=require('PTAR.PTARRouteData')
local M={}
local INDEX='PTAR_Routes.txt'
function M.filename(input)
  if type(input)~='string' then return nil,'Enter a route filename' end
  local suffix=input:gsub('%.lua$',''):gsub('^PTAR_','')
  if not suffix:match('^[%w_%-]+$') or #suffix>80 then
    return nil,'Use letters, digits, underscores or hyphens (up to 80 characters)'
  end
  return 'PTAR_'..suffix..'.lua'
end
function M.accept(name)
  return type(name)=='string' and (name:match('^PTAR_[%w_%-]+%.lua$') ~= nil or
    name=='SleeperTombRoute_runner_test.lua' or name=='SleeperTombRoute.lua')
end
local function names(dir)
  local f=io.open(dir..'/'..INDEX,'r') or io.open(dir..'/'..INDEX..'.bak','r')
  if not f then return {} end
  local list,seen={},{}
  for line in f:lines() do
    local name=line:match('^%s*(.-)%s*$')
    if M.accept(name) and not seen[name] then seen[name]=true; list[#list+1]=name end
  end
  f:close()
  return list
end
M.names=names
function M.scan(dir)
  local list={}
  for _,name in ipairs(names(dir)) do
    local route,err=data.read(dir..'/'..name)
    if route then
      local errors=data.validate(route)
      if #errors==0 then
        list[#list+1]={file=name,name=route.route_name,zone=route.zone_short_name,
          label=string.format('%s [%s] — %s',route.route_name,route.zone_short_name,name)}
      else err=table.concat(errors,'; ') end
    end
    if err then list[#list+1]={file=name,label=name..' [invalid: '..tostring(err)..']',error=tostring(err)} end
  end
  table.sort(list,function(a,b) return a.file:lower()<b.file:lower() end)
  return list
end
function M.add(dir,name)
  if not M.accept(name) then return nil,'Invalid route filename' end
  local route,err=data.read(dir..'/'..name)
  if not route then return nil,'Could not load route: '..tostring(err) end
  local errors=data.validate(route)
  if #errors>0 then return nil,'Invalid route: '..table.concat(errors,'; ') end
  local list=names(dir)
  for _,existing in ipairs(list) do if existing==name then return true end end
  list[#list+1]=name
  local path=dir..'/'..INDEX
  local f,e=io.open(path..'.tmp','w'); if not f then return nil,e end
  local wrote,we=f:write(table.concat(list,'\n')..'\n')
  local closed,ce=f:close()
  if not wrote or not closed then return nil,we or ce end
  local old=io.open(path,'r')
  if old then old:close(); os.remove(path..'.bak'); local ok,rename_err=os.rename(path,path..'.bak')
    if not ok then return nil,rename_err end end
  local ok,rename_err=os.rename(path..'.tmp',path)
  if not ok then os.rename(path..'.bak',path); return nil,rename_err end
  return true
end
return M
