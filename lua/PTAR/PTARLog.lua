local M={}
local function safe(s) return tostring(s or 'unknown'):gsub('[^%w_%-]','_') end
function M.new(dir,identity,clock,version,echo_fn)
  local self={echo=false}
  function self:filename()
    local server,char=identity()
    return 'PTAR_'..safe(server)..'_'..safe(char)..'.log'
  end
  function self:path() return dir..'/'..self:filename() end
  function self:write(level,message)
    local path=self:path()
    local previous=io.open(path,'rb')
    if previous then
      local size=previous:seek('end'); previous:close()
      if size and size>4*1024*1024 then os.remove(path..'.old'); os.rename(path,path..'.old') end
    end
    local f=io.open(path,'a')
    if not f then return end
    local now=clock()
    f:write(string.format('%s.%03d +%dms | %s | %-5s | %s\n',os.date('%Y-%m-%d %H:%M:%S'),now%1000,now,version,level,tostring(message)))
    f:close()
    if level=='DEBUG' and self.echo and echo_fn then pcall(echo_fn,message) end
  end
  function self:event(message) self:write('EVENT',message) end
  function self:debug(message) self:write('DEBUG',message) end
  function self:set_echo(enabled,snapshot)
    self.echo=enabled and true or false
    self:event('MQ Console Echo '..(self.echo and 'ON' or 'OFF'))
    if self.echo and snapshot then self:debug('Enable snapshot: '..snapshot()) end
  end
  return self
end
return M
