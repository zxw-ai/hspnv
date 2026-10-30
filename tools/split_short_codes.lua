-- 把 custom_phrase.dict.yaml 里的「首笔简码」（如 或者=11）改成带分词符的形式（1'1）。
--   目的：让简码与「首两笔选字」不再共用同一个输入串（11 只出单字，1'1 才出简码词）。
--   判定：编码是纯数字、长度等于词的字数、且每一位正好等于对应字的首笔。
--   全码（每字完整码拼接）与其它条目保持原样。
-- 用法：cd lua && lua5.3 ../tools/split_short_codes.lua [--apply]
package.path = './?.lua;' .. package.path

local SRC = '../custom_phrase.dict.yaml'
local APPLY = arg[1] == '--apply'

local stroke = require('stroke')

local out_lines = {}
local changed, kept, skipped = 0, 0, 0
local samples = {}

for line in io.lines(SRC) do
  local word, code, weight = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
  if word and code and code:match('^[1-5]+$') then
    -- 拆字
    local chars = {}
    for ch in word:gmatch("[\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    local n = #chars
    if n >= 2 and #code == n then
      local firsts = {}
      local ok = true
      for i, ch in ipairs(chars) do
        local c = stroke[ch]
        if not c or c == '' then ok = false break end
        firsts[i] = c:sub(1, 1)
      end
      if ok and table.concat(firsts) == code then
        local newcode = table.concat(firsts, "'")
        out_lines[#out_lines + 1] = word .. '\t' .. newcode .. '\t' .. weight
        changed = changed + 1
        if #samples < 8 then samples[#samples + 1] = word .. ' ' .. code .. ' → ' .. newcode end
        goto continue
      end
    end
    skipped = skipped + 1
  end
  out_lines[#out_lines + 1] = line
  ::continue::
end

print(string.format('转换 %d 条简码；未转换的纯数字条目 %d 条；总输出 %d 行', changed, skipped, #out_lines))
for _, s in ipairs(samples) do print('  ' .. s) end

if not APPLY then
  print('（未写入，加 --apply 生效）')
  return
end

-- 备份（同目录 .bak + lua/_backup/ 各一份）
os.execute('cp ../custom_phrase.dict.yaml ../custom_phrase.dict.yaml.bak 2>/dev/null')
os.execute('mkdir -p _backup && cp ../custom_phrase.dict.yaml _backup/custom_phrase.dict.yaml.bak 2>/dev/null')

local f = assert(io.open(SRC, 'w'))
f:write(table.concat(out_lines, '\n'), '\n')
f:close()
print('已写入 custom_phrase.dict.yaml（备份：custom_phrase.dict.yaml.bak 与 lua/_backup/）')
