-- Shared PTAR config/log directory locations.
local M={}
local function directory(path)
  if type(path)~='string' or path=='' or path:find('["\r\n]') then
    return nil,'Invalid MacroQuest directory: '..tostring(path)
  end
  local sep=package.config:sub(1,1)
  local native=path:gsub('/','\\')
  local command=sep=='\\' and ('if not exist "'..native..'" mkdir "'..native..'"') or
    ("mkdir -p '"..path:gsub("'","'\\''").."'")
  local ok=os.execute(command)
  if ok~=true and ok~=0 then return nil,'Could not create '..path end
  return true
end
local function parent(path)
  local clean=path:gsub('[/\\]+$','')
  return clean:match('^(.*)[/\\][^/\\]+$')
end
function M.prepare(config_root,logs_root)
  if type(config_root)~='string' or not parent(config_root) then return nil,'MacroQuest config directory unavailable' end
  local config=config_root:gsub('[/\\]+$','')..'/PTAR'
  local logs=(logs_root and logs_root:gsub('[/\\]+$','') or parent(config_root)..'/logs')..'/PTAR'
  local ok,err=directory(config); if not ok then return nil,err end
  ok,err=directory(logs); if not ok then return nil,err end
  return {config=config,logs=logs}
end
return M
