-- 从领域词表里挑出「词库没有 + 笔画可打」的词
--   过滤：纯汉字 / 长度 2~4 / 每个字都在 stroke.lua 笔画表里 / 不在 words.lua
--   排序：按领域词表给出的频率降序，每类取前 N
-- 用法：cd lua && lua5.3 ../tools/pick_domain_words.lua <每类上限> <输出文件> <领域txt>...
--   例：lua5.3 ../tools/pick_domain_words.lua 300 /tmp/picked.txt /tmp/dom/网络用语.txt ...
package.path = './?.lua;' .. package.path

local LIMIT = tonumber(arg[1]) or 300
local OUT = arg[2] or '/tmp/picked.txt'
local files = {}
for i = 3, #arg do files[#files + 1] = arg[i] end
if #files == 0 then
  print('用法: lua5.3 ../tools/pick_domain_words.lua <每类上限> <输出> <领域txt>...')
  return
end

local words = require('words')
local stroke = require('stroke')

local function utf8_chars(s)
  local t = {}
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
  return t
end

local function is_cjk(ch)
  local b = ch:byte(1)
  return b and b >= 0xE4 and b <= 0xE9
end

local seen = {}
local out = assert(io.open(OUT, 'w'))
local total_picked = 0

for _, path in ipairs(files) do
  local name = path:match('([^/]+)%.txt$') or path
  local rows = {}
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      local w, n = line:match('^([^\t]+)\t(%d+)$')
      if w then
        rows[#rows + 1] = { w = w, n = tonumber(n) }
      end
    end
    f:close()
  end
  table.sort(rows, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.w < b.w
  end)

  -- 多取一些候选再筛（很多会被过滤掉）
  local picked = {}
  local scanned = 0
  for _, r in ipairs(rows) do
    scanned = scanned + 1
    if #picked >= LIMIT then break end
    local w = r.w
    if not seen[w] and not words[w] then
      local chars = utf8_chars(w)
      local ok = #chars >= 2 and #chars <= 4
      if ok then
        for _, ch in ipairs(chars) do
          if not is_cjk(ch) or not stroke[ch] then ok = false break end
        end
      end
      if ok then
        seen[w] = true
        picked[#picked + 1] = w
      end
    end
  end
  print(string.format('%-12s 扫描 %d 行 → 新增 %d 个', name, scanned, #picked))
  for _, w in ipairs(picked) do
    out:write(w, '\t', name, '\n')
    total_picked = total_picked + 1
  end
end
out:close()
print(string.format('合计 %d 个 → %s', total_picked, OUT))
