-- 从 custom_phrase.dict.yaml 提取「带分词符的简码」→ lua/quick_codes.lua
-- 目的：不依赖 Rime 对带 ' 编码的支持，由 segment_phrase 自己精确命中并置顶。
-- 表结构：{ ["1'1"] = {"或者", ...}, ... }（同码多词按权重/原序保留前 3 个）
-- 用法：cd lua && lua5.3 ../tools/gen_quick_codes.lua [--apply]
package.path = './?.lua;' .. package.path

local SRC = '../custom_phrase.dict.yaml'
local APPLY = arg[1] == '--apply'
local MAX_PER_CODE = 3

local map, order = {}, {}
local total = 0

for line in io.lines(SRC) do
  local word, code, weight = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
  if word and code and code:find("'", 1, true) and code:match("^[1-5']+$") then
    total = total + 1
    local list = map[code]
    if not list then
      list = {}
      map[code] = list
      order[#order + 1] = code
    end
    if #list < MAX_PER_CODE then list[#list + 1] = word end
  end
end

print(string.format('带分词符的简码条目 %d 条，去重后 %d 个编码', total, #order))

if not APPLY then
  for i = 1, math.min(#order, 6) do
    local c = order[i]
    print(string.format('  %s → %s', c, table.concat(map[c], ' / ')))
  end
  print('（未写入，加 --apply 生效）')
  return
end

local out = {}
out[#out + 1] = '-- 简码表（tools/gen_quick_codes.lua 生成，来自 custom_phrase.dict.yaml 的带分词符简码）'
out[#out + 1] = '-- 结构：["1\'1"] = {"或者", ...}；segment_phrase 在分词输入时精确命中并置顶'
out[#out + 1] = 'return {'
for _, code in ipairs(order) do
  local parts = {}
  for _, w in ipairs(map[code]) do parts[#parts + 1] = string.format('%q', w) end
  out[#out + 1] = string.format('  [%q]={%s},', code, table.concat(parts, ','))
end
out[#out + 1] = '}'

local f = assert(io.open('quick_codes.lua', 'w'))
f:write(table.concat(out, '\n'))
f:close()
print('已写入 lua/quick_codes.lua')
