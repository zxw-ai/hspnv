-- 把 head_words 从「每桶一个 { {词,频}, ... } 数组」打包成「每桶一个字符串」，
-- 运行时按需解析（预测时才用，桶均 26 条，解析开销可忽略）。
-- 目的：94,594 个两元素小表 → 3556 个字符串，Lua 内存 19MB → 约 2MB。
-- 用法：cd lua && lua5.3 ../tools/pack_head_words.lua [--apply]
package.path = './?.lua;' .. package.path

local APPLY = arg[1] == '--apply'

local hw = require('head_words')
local buckets, entries = 0, 0
local out_lines = {}
out_lines[#out_lines + 1] = '-- 打包版 head_words（tools/pack_head_words.lua 生成）'
out_lines[#out_lines + 1] = '-- 格式：["首字"]="词1<TAB>频1|词2<TAB>频2|..."，运行时按需解析'
out_lines[#out_lines + 1] = 'return {'
local line = '  '
for ch, arr in pairs(hw) do
  buckets = buckets + 1
  local parts = {}
  for _, item in ipairs(arr) do
    local w, f = item[1], item[2]
    if w and f then
      parts[#parts + 1] = w .. '\t' .. tostring(f)
      entries = entries + 1
    end
  end
  local piece = string.format('[%q]=%q,', ch, table.concat(parts, '|'))
  if #line + #piece > 150 then
    out_lines[#out_lines + 1] = line
    line = '  '
  end
  line = line .. piece
end
if line ~= '  ' then out_lines[#out_lines + 1] = line end
out_lines[#out_lines + 1] = '}'

print(string.format('桶 %d，条目 %d', buckets, entries))
if not APPLY then
  print('（未写入，加 --apply 生效）')
  return
end
os.execute('mkdir -p _backup')
os.execute('cp head_words.lua _backup/head_words.lua.bak 2>/dev/null')
local f = assert(io.open('head_words.lua', 'w'))
f:write(table.concat(out_lines, '\n'))
f:close()
print('已写入 head_words.lua（备份在 lua/_backup/）')
