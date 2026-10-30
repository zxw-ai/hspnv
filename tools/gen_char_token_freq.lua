-- 生成 char_freq_token.lua：按词频加权的「字 token 频率」
-- 用途：句子级 DP 的概率打底（P(字)），比「以该字开头的词频和」口径更接近真实字频。
-- 运行：cd lua && lua5.3 ../tools/gen_char_token_freq.lua
package.path = './?.lua;' .. package.path

local words = require('words')

local token = {}
local total_words = 0
local total_chars = 0

for w, f in pairs(words) do
  if type(f) == 'number' and f > 0 then
    total_words = total_words + f
    local n = 0
    for ch in w:gmatch("[\1-\127\194-\244][\128-\191]*") do
      token[ch] = (token[ch] or 0) + f
      n = n + 1
    end
    total_chars = total_chars + f * n
  end
end

local keys = {}
for ch in pairs(token) do keys[#keys + 1] = ch end
table.sort(keys)

local out = {}
out[#out + 1] = '-- 自动生成（tools/gen_char_token_freq.lua）：按词频加权的字 token 频率'
out[#out + 1] = '-- 用于句子级 DP 的真实概率打分：P(ch) = chars[ch] / total_chars'
out[#out + 1] = 'return {'
out[#out + 1] = string.format('  total_words = %.0f,', total_words)
out[#out + 1] = string.format('  total_chars = %.0f,', total_chars)
out[#out + 1] = '  chars = {'
local line = '   '
for i, ch in ipairs(keys) do
  local piece = string.format(' ["%s"]=%.0f,', ch, token[ch])
  if #line + #piece > 150 then
    out[#out + 1] = line
    line = '   '
  end
  line = line .. piece
end
if line ~= '   ' then out[#out + 1] = line end
out[#out + 1] = '  },'
out[#out + 1] = '}'

local f = assert(io.open('char_freq_token.lua', 'w'))
f:write(table.concat(out, '\n'))
f:close()

print(string.format('chars=%d total_words=%.0f total_chars=%.0f', #keys, total_words, total_chars))
