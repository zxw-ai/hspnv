-- 裁剪离线预测词表（减小体积/加载时间/内存）
--   next_words_tri：只保留「前两个词词频都 >= MIN_WORD_FREQ」的键，每个键最多 MAX_TRI 个后接词
--   next_words_big：只保留「前词词频 >= MIN_WORD_FREQ」的键，每个键最多 MAX_BIG 个后接词
-- 用法：cd lua && lua5.3 ../tools/trim_predict_tables.lua [--apply]
--   不加 --apply 只统计；加 --apply 会备份原文件并覆盖。
package.path = './?.lua;' .. package.path

local MIN_WORD_FREQ = 100
local MAX_TRI = 8
local MAX_BIG = 12
local APPLY = arg[1] == '--apply'

local words = require('words')

local function load_mod(name)
  local ok, t = pcall(require, name)
  return ok and type(t) == 'table' and t or {}
end

local tri = load_mod('next_words_tri')
local big = load_mod('next_words_big')

local function emit_table(path, data, header)
  local out = {}
  out[#out + 1] = header
  out[#out + 1] = 'return {'
  local line = '  '
  for k, v in pairs(data) do
    local piece = string.format('[%q]={', k)
    for i = 1, #v do
      piece = piece .. string.format('%q,', v[i])
    end
    piece = piece .. '},'
    if #line + #piece > 160 then
      out[#out + 1] = line
      line = '  '
    end
    line = line .. piece
  end
  if line ~= '  ' then out[#out + 1] = line end
  out[#out + 1] = '}'
  local f = assert(io.open(path, 'w'))
  f:write(table.concat(out, '\n'))
  f:close()
end

-- tri
local tri_out, n_tri_in, n_tri_out, e_in, e_out = {}, 0, 0, 0, 0
for k, v in pairs(tri) do
  n_tri_in = n_tri_in + 1
  e_in = e_in + #v
  local a, b = k:match('^([^\t]+)\t([^\t]+)$')
  if a then
    local fa = words[a] or 0
    local fb = words[b] or 0
    if fa >= MIN_WORD_FREQ and fb >= MIN_WORD_FREQ then
      local keep = {}
      for i = 1, math.min(#v, MAX_TRI) do keep[i] = v[i] end
      tri_out[k] = keep
      n_tri_out = n_tri_out + 1
      e_out = e_out + #keep
    end
  end
end

-- big
local big_out, n_big_in, n_big_out, eb_in, eb_out = {}, 0, 0, 0, 0
for k, v in pairs(big) do
  n_big_in = n_big_in + 1
  eb_in = eb_in + #v
  if (words[k] or 0) >= MIN_WORD_FREQ then
    local keep = {}
    for i = 1, math.min(#v, MAX_BIG) do keep[i] = v[i] end
    big_out[k] = keep
    n_big_out = n_big_out + 1
    eb_out = eb_out + #keep
  end
end

print(string.format('tri: key %d→%d, entry %d→%d', n_tri_in, n_tri_out, e_in, e_out))
print(string.format('big: key %d→%d, entry %d→%d', n_big_in, n_big_out, eb_in, eb_out))

if not APPLY then
  print('（未写入，加 --apply 生效）')
  return
end

os.execute('mkdir -p _backup')
os.execute('cp next_words_tri.lua _backup/next_words_tri.lua.bak 2>/dev/null')
os.execute('cp next_words_big.lua _backup/next_words_big.lua.bak 2>/dev/null')

emit_table('next_words_tri.lua', tri_out,
  '-- 裁剪版离线 Trigram（tools/trim_predict_tables.lua 生成；只保留常用前词组合，每键≤8）')
emit_table('next_words_big.lua', big_out,
  '-- 裁剪版离线 Bigram（tools/trim_predict_tables.lua 生成；只保留常用前词，每键≤12）')
print('已写入 next_words_tri.lua / next_words_big.lua（备份在 lua/_backup/）')
