-- 生成个人语料 n-gram：把一段纯文本切成句子 → 最大匹配分词 → 统计 bigram / trigram
-- 用法：cd lua && lua5.3 ../tools/gen_personal_ngram.lua ../personal_corpus.txt
-- 输出：<方案目录>/personal_ngram.tsv（ngram.lua 启动时会把它作为「低权重种子」并入上下文模型）
--
-- 说明：只用 words.lua 做词典（不做新词发现），标点/英文/数字会被跳过；
--       统计结果里每条计数封顶 MAX_COUNT，避免盖过用户实时上屏学习的数据。
package.path = './?.lua;' .. package.path

local words = require('words')

local MAX_COUNT = 2          -- 单条 n-gram 的最大计数
local MAX_WORD_LEN = 4       -- 最大匹配的词长上限（按字）
local MIN_SENTENCE = 2       -- 少于该词数的句子不统计

local input = arg[1] or '../personal_corpus.txt'
local out_path = arg[2] or '../personal_ngram.tsv'

local function utf8_chars(s)
  local t = {}
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
  return t
end

local function is_cjk(ch)
  local b = ch:byte(1)
  return b and b >= 0xE4 and b <= 0xE9
end

-- 分词：小 DP（不是最长匹配）。
-- 最长匹配会被词库里的长短语带偏（例：「这个价」是词条 → 价格 被拆成 价/格）。
-- DP 用 log 词频 + 长度惩罚，2 字词优先，长词要「足够高频」才合并。
local LEN_PENALTY = 1.0
local function segment(sentence)
  local chars = utf8_chars(sentence)
  local n = #chars
  local best = { [0] = { score = 0, toks = {} } }
  for i = 1, n do
    local cur = nil
    for len = 1, math.min(MAX_WORD_LEN, i) do
      local prev = best[i - len]
      if prev then
        local w = table.concat(chars, '', i - len + 1, i)
        local ok = (len == 1) or (is_cjk(chars[i]) and words[w] ~= nil)
        if ok then
          local f = words[w] or 1
          local sc = prev.score + math.log10(f + 1) - LEN_PENALTY * (len - 1)
          if not cur or sc > cur.score then
            local toks = {}
            for _, t in ipairs(prev.toks) do toks[#toks + 1] = t end
            toks[#toks + 1] = w
            cur = { score = sc, toks = toks }
          end
        end
      end
    end
    best[i] = cur
  end
  local toks = best[n] and best[n].toks or {}
  -- 过滤非汉字 token（标点/字母）
  local out = {}
  for _, t in ipairs(toks) do
    local ok = true
    for ch in t:gmatch("[\1-\127\194-\244][\128-\191]*") do
      if not is_cjk(ch) then ok = false break end
    end
    if ok then out[#out + 1] = t end
  end
  return out
end

local bigram, trigram = {}, {}
local function add(t, k)
  t[k] = (t[k] or 0) + 1
end

local f = assert(io.open(input, 'r'))
local text = f:read('a')
f:close()

-- 按标点/换行切句（必须按「字符」切，不能用 Lua 的字节字符类，否则会切坏多字节汉字）
local PUNCT = {}
for ch in ("。！？!?；;，,、") :gmatch("[\1-\127\194-\244][\128-\191]*") do PUNCT[ch] = true end
local n_sent, n_tokens = 0, 0
local function handle_sentence(sentence)
  local toks = segment(sentence)
  if #toks < MIN_SENTENCE then return end
  n_sent = n_sent + 1
  n_tokens = n_tokens + #toks
  for i = 1, #toks - 1 do
    add(bigram, toks[i] .. '\t' .. toks[i + 1])
    if i + 2 <= #toks then
      add(trigram, toks[i] .. '\t' .. toks[i + 1] .. '\t' .. toks[i + 2])
    end
  end
end
for line in text:gmatch('[^\r\n]+') do
  local buf = {}
  for ch in line:gmatch("[\1-\127\194-\244][\128-\191]*") do
    if PUNCT[ch] then
      handle_sentence(table.concat(buf))
      buf = {}
    else
      buf[#buf + 1] = ch
    end
  end
  if #buf > 0 then handle_sentence(table.concat(buf)) end
end

-- 只保留「被预测词」至少 2 个字的条目：
-- 单字跟随者绝大多数是分词切碎的 的/了/是/我，作为联想候选没有价值，
-- 还会把有价值的双字词挤出候选区。
local function char_len(w)
  local n = 0
  for _ in w:gmatch("[\1-\127\194-\244][\128-\191]*") do n = n + 1 end
  return n
end

local out = assert(io.open(out_path, 'w'))
local nb, nt, skipped = 0, 0, 0
for k, n in pairs(bigram) do
  local _, b = k:match('^([^\t]+)\t([^\t]+)$')
  if b and char_len(b) >= 2 then
    out:write('W\t', k, '\t', tostring(math.min(n, MAX_COUNT)), '\n')
    nb = nb + 1
  else
    skipped = skipped + 1
  end
end
for k, n in pairs(trigram) do
  local a, b, c = k:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
  if c and char_len(c) >= 2 then
    out:write('T\t', a, '\t', b, '\t', c, '\t', tostring(math.min(n, MAX_COUNT)), '\n')
    nt = nt + 1
  else
    skipped = skipped + 1
  end
end
out:close()

print(string.format('句子 %d，词 %d，bigram %d，trigram %d（跳过单字尾 %d）→ %s', n_sent, n_tokens, nb, nt, skipped, out_path))
