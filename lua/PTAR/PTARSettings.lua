-- Per-server/character runtime preferences (last-used route, MQ-console echo, multi-box door role).
-- Plain key=value text, atomic saves (same tmp/bak/promote pattern as PTARFiles' route index).
local files=require('PTAR.PTARFiles')
local M={}
local function safe(s) return tostring(s or 'unknown'):gsub('[^%w_%-]','_') end
function M.filename(identity)
  local server,char=identity()
  return 'PTAR_Settings_'..safe(server)..'_'..safe(char)..'.txt'
end
function M.path(dir,identity) return dir..'/'..M.filename(identity) end
function M.read(dir,identity)
  local f=io.open(M.path(dir,identity),'r')
  if not f then return {} end
  local settings={}
  for line in f:lines() do
    local key,value=line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
    if key then settings[key]=value end
  end
  f:close()
  if settings.last_route and not files.accept(settings.last_route) then settings.last_route=nil end
  if settings.echo_enabled=='true' then settings.echo_enabled=true
  elseif settings.echo_enabled=='false' then settings.echo_enabled=false
  else settings.echo_enabled=nil end
  if settings.door_role~='primary' and settings.door_role~='secondary' then settings.door_role=nil end
  return settings
end
function M.save(dir,identity,settings)
  local path=M.path(dir,identity)
  local lines={}
  if settings.last_route then lines[#lines+1]='last_route='..settings.last_route end
  if settings.echo_enabled~=nil then lines[#lines+1]='echo_enabled='..tostring(settings.echo_enabled) end
  if settings.door_role=='primary' or settings.door_role=='secondary' then lines[#lines+1]='door_role='..settings.door_role end
  local f,e=io.open(path..'.tmp','w'); if not f then return nil,e end
  local wrote,we=f:write(table.concat(lines,'\n')..'\n')
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
