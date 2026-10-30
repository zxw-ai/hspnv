-- 往 custom_phrase.dict.yaml 里加自造词（自动算全码 + 简码）
--   全码：每字完整笔画码直接拼接（如 我们 = 312153432425）
--   简码：每字首笔 + ' 分隔（如 我们 = 3'3，2026-10-30 起的新格式）
-- 用法：
--   cd lua && lua5.3 ../tools/add_words.lua --dry-run 彭泽人 老家话      # 只看结果
--   cd lua && lua5.3 ../tools/add_words.lua --apply   彭泽人 老家话      # 写入
--   cd lua && lua5.3 ../tools/add_words.lua --apply --file ../new_words.txt  # 从文件读（一行一个词）
package.path = './?.lua;' .. package.path

local APPLY = false
local FROM_FILE = nil
local words_in = {}
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == '--apply' then APPLY = true
  elseif a == '--dry-run' then APPLY = false
  elseif a == '--file' then FROM_FILE = arg[i + 1]; i = i + 1
  elseif a:sub(1, 2) ~= '--' then words_in[#words_in + 1] = a end
  i = i + 1
end
if FROM_FILE then
  local f = io.open(FROM_FILE, 'r')
  if f then
    for line in f:lines() do
      local w = line:match('^%s*([^%s#]+)')
      if w then words_in[#words_in + 1] = w end
    end
    f:close()
  else
    print('读不到文件: ' .. FROM_FILE)
    return
  end
end
if #words_in == 0 then
  print('用法: lua5.3 ../tools/add_words.lua [--apply] 词1 词2 ...  |  --file 词表.txt')
  return
end

local stroke = require('stroke')
local SRC = '../custom_phrase.dict.yaml'

local existing, lines = {}, {}
for line in io.lines(SRC) do
  lines[#lines + 1] = line
  local word, code = line:match('^([^\t]+)\t([^\t]+)\t')
  if word and code then existing[word .. '\t' .. code] = true end
end

local function codes_of(word)
  local chars = {}
  for ch in word:gmatch("[\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  if #chars == 0 then return nil, '空词' end
  local full, firsts = {}, {}
  for idx, ch in ipairs(chars) do
    local c = stroke[ch]
    if not c or c == '' then return nil, '笔画表里没有「' .. ch .. '」' end
    full[idx] = c
    firsts[idx] = c:sub(1, 1)
  end
  local full_code = table.concat(full)
  local short_code = nil
  if #chars >= 2 then short_code = table.concat(firsts, "'") end
  return full_code, short_code
end

local added, skipped, failed = {}, {}, {}
for _, w in ipairs(words_in) do
  local full, short = codes_of(w)
  if not full then
    failed[#failed + 1] = w .. '（' .. tostring(short) .. '）'
  else
    local function push(code, kind)
      if existing[w .. '\t' .. code] then
        skipped[#skipped + 1] = w .. ' ' .. code
      else
        existing[w .. '\t' .. code] = true
        lines[#lines + 1] = w .. '\t' .. code .. '\t5'
        added[#added + 1] = string.format('%s\t%s\t(%s)', w, code, kind)
      end
    end
    push(full, '全码')
    if short then push(short, '简码') end
  end
end

print(string.format('待加词 %d 个：新增 %d 条、已存在 %d 条、失败 %d 个',
  #words_in, #added, #skipped, #failed))
for _, s in ipairs(added) do print('  + ' .. s) end
for _, s in ipairs(failed) do print('  ! ' .. s) end

if not APPLY then
  print('（--dry-run，未写入；加 --apply 生效）')
  return
end
if #added == 0 then
  print('没有需要写入的条目')
  return
end

os.execute('cp ../custom_phrase.dict.yaml ../custom_phrase.dict.yaml.bak 2>/dev/null')
os.execute('mkdir -p _backup && cp ../custom_phrase.dict.yaml _backup/custom_phrase.dict.yaml.bak 2>/dev/null')
local f = assert(io.open(SRC, 'w'))
f:write(table.concat(lines, '\n'), '\n')
f:close()
print('已写入 ' .. SRC .. '（备份：custom_phrase.dict.yaml.bak）')

os.execute('lua5.3 ../tools/gen_quick_codes.lua --apply')
print('记得重新部署方案（词库变了），简码表已同步更新')
