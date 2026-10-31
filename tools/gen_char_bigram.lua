-- 统计「字 → 字」的二元搭配，供整句解码（逐字路径）打分使用
--   来源1：词库 words 的词内相邻字（按词频加权）
--   来源2：离线 bigram 表 next_words_big 的「前词末字 → 后词首字」（跨词搭配，权重 1）
-- 输出：lua/char_bigram.lua  { total = N, pairs = { ["字1\t字2"] = 次数 } }
-- 用法：cd lua && lua5.3 ../tools/gen_char_bigram.lua [--apply] [--min 100] [--max 80000]
package.path = './?.lua;' .. package.path

local APPLY = false
local MIN_COUNT = 100
local MAX_PAIRS = 80000
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == '--apply' then APPLY = true
  elseif a == '--min' then MIN_COUNT = tonumber(arg[i + 1]) or MIN_COUNT; i = i + 1
  elseif a == '--max' then MAX_PAIRS = tonumber(arg[i + 1]) or MAX_PAIRS; i = i + 1
  end
  i = i + 1
end

local words = require('words')
local cb, total = {}, 0
local function add(a, b, f)
  if not a or not b or a == '' or b == '' then return end
  local k = a .. '\t' .. b
  cb[k] = (cb[k] or 0) + f
  total = total + f
end

-- 1) 词内相邻字
for w, f in pairs(words) do
  local chars = {}
  for ch in w:gmatch("[\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  for j = 1, #chars - 1 do add(chars[j], chars[j + 1], f) end
end
local n_word = 0
for _ in pairs(cb) do n_word = n_word + 1 end

-- 2) 跨词：前词末字 → 后词首字
local ok_nb, nb = pcall(require, 'next_words_big')
if ok_nb and type(nb) == 'table' then
  for prev, list in pairs(nb) do
    local last = nil
    for ch in prev:gmatch("[\1-\127\194-\244][\128-\191]*") do last = ch end
    if last then
      for _, w in ipairs(list) do
        local first = w:match("^[\1-\127\194-\244][\128-\191]*")
        add(last, first, 1)
      end
    end
  end
end

-- 过滤 + 截断
local arr = {}
for k, n in pairs(cb) do
  if n >= MIN_COUNT then arr[#arr + 1] = { k = k, n = n } end
end
table.sort(arr, function(a, b) return a.n > b.n end)
if #arr > MAX_PAIRS then
  for j = #arr, MAX_PAIRS + 1, -1 do arr[j] = nil end
end
local kept = 0
for _, x in ipairs(arr) do kept = kept + x.n end

print(string.format('词内字对 %d 个；过滤后保留 %d 条（min=%d），覆盖计数 %d',
  n_word, #arr, MIN_COUNT, kept))

if not APPLY then
  print('（未写入，加 --apply 生效）')
  return
end

local out = {}
out[#out + 1] = '-- 字二元搭配（tools/gen_char_bigram.lua 生成）'
out[#out + 1] = '-- 来源：词库词内相邻字（按词频）+ 离线 bigram 的跨词首尾字'
out[#out + 1] = '-- 结构：{ total = 总计数, pairs = { ["字1\t字2"] = 次数 } }'
out[#out + 1] = 'return {'
out[#out + 1] = string.format('  total = %d,', kept)
out[#out + 1] = '  pairs = {'
local line = '   '
for _, x in ipairs(arr) do
  local piece = string.format(' [%q]=%d,', x.k, x.n)
  if #line + #piece > 150 then
    out[#out + 1] = line
    line = '   '
  end
  line = line .. piece
end
if line ~= '   ' then out[#out + 1] = line end
out[#out + 1] = '  },'
out[#out + 1] = '}'

local f = assert(io.open('char_bigram.lua', 'w'))
f:write(table.concat(out, '\n'))
f:close()
print('已写入 lua/char_bigram.lua')
