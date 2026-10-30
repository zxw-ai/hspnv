-- 把 phrase_stroke_index 的 I 表从「每个键一个 {offset,count} 小表」压成「一个整数」：
--   I[key] = offset * 128 + count      (count <= 127)
-- 158,774 个小表 → 158,774 个数字，运行时内存约省 8~10MB；查询只是多一次整除/取余。
-- 用法：cd lua && lua5.3 ../tools/pack_phrase_index.lua [--apply]
package.path = './?.lua;' .. package.path

local APPLY = arg[1] == '--apply'
local old = require('phrase_stroke_index')

local nameI, I = debug.getupvalue(old.get, 2)
local nameD, D = debug.getupvalue(old.get, 3)
assert(nameI == 'I' and type(I) == 'table', 'I 表读取失败')
assert(nameD == 'D' and type(D) == 'table', 'D 表读取失败')

local nk, maxoff, maxcnt = 0, 0, 0
for _, z in pairs(I) do
  nk = nk + 1
  if z[1] > maxoff then maxoff = z[1] end
  if z[2] > maxcnt then maxcnt = z[2] end
end
print(string.format('keys=%d D=%d maxoffset=%d maxcount=%d', nk, #D, maxoff, maxcnt))
assert(maxcnt <= 127, 'count 超过 127，需要换打包位数')

if not APPLY then
  print('（未写入，加 --apply 生效）')
  return
end

local out = {}
out[#out + 1] = '-- 扁平精确词组索引（打包版：I[key] = offset*128 + count）'
out[#out + 1] = '-- 由 tools/pack_phrase_index.lua 生成；候选按需解码'
out[#out + 1] = 'local I={'
local line = ''
for k, z in pairs(I) do
  local piece = string.format('[%q]=%d,', k, z[1] * 128 + z[2])
  if #line + #piece > 150 then
    out[#out + 1] = line
    line = ''
  end
  line = line .. piece
end
if line ~= '' then out[#out + 1] = line end
out[#out + 1] = '}'

-- D：扁平候选数组（词, 频, 词, 频, ...）
local buf = {}
for i = 1, #D, 4000 do
  local chunk = {}
  for j = i, math.min(i + 3999, #D) do
    local v = D[j]
    if type(v) == 'number' then chunk[#chunk + 1] = tostring(v)
    else chunk[#chunk + 1] = string.format('%q', v) end
  end
  buf[#buf + 1] = table.concat(chunk, ',')
end
out[#out + 1] = 'local D={' .. table.concat(buf, ',') .. ',}'
out[#out + 1] = [[
local cache={}
local order={}
local LIMIT=96
local function get(k)
  local c=cache[k]
  if c then return c end
  local z=I[k]
  if not z then return nil end
  local p=z-(z%128)
  p=p/128
  local n=z%128
  c={}
  for i=1,n do c[i]={D[p],D[p+1]} p=p+2 end
  cache[k]=c
  order[#order+1]=k
  if #order>LIMIT then cache[table.remove(order,1)]=nil end
  return c
end
local M={get=get,count=function()local n=0 for _ in pairs(I)do n=n+1 end return n end}
setmetatable(M,{__index=function(_,k)return get(k)end})
return M
]]
os.execute('mkdir -p _backup')
os.execute('cp phrase_stroke_index.lua _backup/phrase_stroke_index.lua.bak 2>/dev/null')
local f = assert(io.open('phrase_stroke_index.lua', 'w'))
f:write(table.concat(out, '\n'))
f:close()
print('已写入 phrase_stroke_index.lua（备份在 lua/_backup/）')
