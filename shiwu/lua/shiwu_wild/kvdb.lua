-- D1：冷路径大表的二进制读取器（next_words_big / next_words_tri / phrase_stroke_index）
-- 这三张表每次按键只查 1~3 次（不是逐候选查），所以「二分 + 字符串」的开销可以接受，
-- 换来的是常驻内存从 ~24MB（三张 Lua 表）降到 ~3.5MB（三个二进制串）。
-- 用法：
--   local kv = require('hspnv.kvdb').open('lua/data/next_big.bin')
--   kv:get_list('辣椒') -> {"酱","油",...}
--   kv:get_u32("31'32") -> offset*128+count
--   kv:proxy()          -> 可直接 t[key] 访问
local M = {}
local unpack = string.unpack

function M.open(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  if not s or #s < 25 or s:sub(1, 4) ~= 'KV01' then return nil end
  local typ = s:byte(5)
  local stride, count, nblock, index_off = unpack('<I4I4I4I4', s, 6)
  local data_off = unpack('<I4', s, 22)
  if not count or not nblock or nblock == 0 or data_off > #s then return nil end
  return setmetatable({
    blob = s, typ = typ, stride = stride, count = count, nblock = nblock,
    index_off = index_off, data_off = data_off, data_len = #s - data_off,
  }, { __index = M })
end

function M:block_off(i)
  return (unpack('<I4', self.blob, self.index_off + (i - 1) * 4 + 1))
end

-- 读一条记录的键与「值起点」，返回 key, value_off, next_off
function M:rec_at(off)
  if off >= self.data_len then return nil end
  local b = self.blob
  local p = self.data_off + off + 1
  if p + 1 > #b then return nil end
  local klen = unpack('<H', b, p)
  local key = b:sub(p + 2, p + 1 + klen)
  local vpos = p + 2 + klen
  if self.typ == 1 then
    local val = unpack('<I4', b, vpos)
    return key, val, off + 2 + klen + 4
  end
  local n = unpack('<H', b, vpos)
  local q = vpos + 2
  local items = {}
  if self.typ == 3 then
    for i = 1, n do
      local ilen = b:byte(q)
      if not ilen then break end
      local w = b:sub(q + 1, q + ilen)
      local f = unpack('<I4', b, q + 1 + ilen)
      items[i] = { w, f }
      q = q + 1 + ilen + 4
    end
  else
    for i = 1, n do
      local ilen = b:byte(q)
      if not ilen then break end
      items[i] = b:sub(q + 1, q + ilen)
      q = q + 1 + ilen
    end
  end
  return key, items, off + (q - (self.data_off + off + 1))
end

function M:lookup(key)
  local lo, hi = 1, self.nblock
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local k = self:rec_at(self:block_off(mid))
    if k == nil then
      hi = mid - 1
    elseif k == key then
      local _, v = self:rec_at(self:block_off(mid))
      return v
    elseif k < key then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if hi < 1 then return nil end
  local off = self:block_off(hi)
  for _ = 1, self.stride do
    local k, v, nxt = self:rec_at(off)
    if not k then return nil end
    if k == key then return v end
    if k > key then return nil end
    off = nxt
  end
  return nil
end

function M:get_u32(key) return self:lookup(key) end
function M:get_list(key) return self:lookup(key) end

function M:each()
  local off = 0
  return function()
    if off >= self.data_len then return nil end
    local k, v, nxt = self:rec_at(off)
    if not k then return nil end
    off = nxt
    return k, v
  end
end

function M:proxy()
  local db = self
  return setmetatable({}, { __index = function(_, k) return db:lookup(k) end })
end

return M
