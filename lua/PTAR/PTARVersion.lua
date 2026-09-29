-- Single authoritative version value, shared by the Runner, Editor, and logger.
local M={}
M.VERSION='0.2.0-test.33'
function M.is_test() return M.VERSION:match('%-test%.')~=nil end
return M
