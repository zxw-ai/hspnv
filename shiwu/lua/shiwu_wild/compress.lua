-- 流式贪心压缩：每凑齐一个部件立即确定，未决部分等待下一笔
local M = {}

local SINGLE = {["1"]="q", ["2"]="w", ["3"]="e", ["4"]="r", ["5"]="t"}
local PARTS = {
  {"251", "s"},
  {"121", "k"},
  {"441", "z"},
  {"312", "v"},
  {"122", "b"},
  {"12", "a"},
  {"13", "d"},
  {"41", "f"},
  {"32", "g"},
  {"45", "h"},
  {"35", "j"},
  {"52", "l"},
  {"31", "m"},
  {"51", "x"},
  {"34", "c"},
}
-- 按长度降序，长部件优先
table.sort(PARTS, function(a, b) return #a[1] > #b[1] end)

-- 返回已确定的压缩码（末尾未决的笔画丢弃）
function M.stream(seq)
  local out = {}
  local i = 1
  local n = #seq
  while i <= n do
    local matched = false
    for _, p in ipairs(PARTS) do
      local pl = #p[1]
      if i + pl - 1 <= n and seq:sub(i, i+pl-1) == p[1] then
        out[#out+1] = p[2]
        i = i + pl
        matched = true
        break
      end
    end
    if not matched then
      -- 当前剩余部分是否可能是某部件的开头
      local pending = false
      local rest = n - i + 1
      for _, p in ipairs(PARTS) do
        local pl = #p[1]
        if pl > rest and seq:sub(i, i+rest-1) == p[1]:sub(1, rest) then
          pending = true
          break
        end
      end
      if pending then break end
      local ch = seq:sub(i, i)
      if SINGLE[ch] then
        out[#out+1] = SINGLE[ch]
      end
      i = i + 1
    end
  end
  return table.concat(out), i - 1
end

-- 全部输入的完整压缩（含最后一次未决部分按单笔处理，用于精确匹配）
function M.full(seq)
  local out = {}
  local i = 1
  local n = #seq
  while i <= n do
    local matched = false
    for _, p in ipairs(PARTS) do
      local pl = #p[1]
      if i + pl - 1 <= n and seq:sub(i, i+pl-1) == p[1] then
        out[#out+1] = p[2]
        i = i + pl
        matched = true
        break
      end
    end
    if not matched then
      local ch = seq:sub(i, i)
      if SINGLE[ch] then out[#out+1] = SINGLE[ch] end
      i = i + 1
    end
  end
  return table.concat(out)
end

return M
