-- lm.lua：轻量语言模型分（log10 概率）
-- 目的：把「词频/字频」换算成同一量纲的概率，供句子级 DP 正确比较
--       「拆成单字」与「合成一个词」的优劣（等价于 PMI 判断），不再靠拍脑袋的常数加权。
--
-- 口径：
--   P(w)  = words[w] / Σ words            （词表里没有的词 → -12，极小）
--   P(ch) = token[ch] / total_chars       （按词频加权的字 token 频率）
--   P(w|prev) 归一化：log10( (cnt/Σcnt) × 后继词种类数 )，即「比均匀分布好多少」，
--   没有用户记录时退回离线 next_words_big 的排名近似；无信息返回 nil。
local M = {}

local LOG10 = math.log10
local words, token, ngram_ref, next_big

local function ensure()
  if words then return end
  local ok, w = pcall(require, 'words'); if ok and type(w) == 'table' then words = w end
  local ok2, t = pcall(require, 'char_freq_token'); if ok2 and type(t) == 'table' then token = t end
  local ok3, n = pcall(require, 'ngram'); if ok3 and type(n) == 'table' then ngram_ref = n end
  local ok4, b = pcall(require, 'next_words_big'); if ok4 and type(b) == 'table' then next_big = b end
  M.ready = (words ~= nil and token ~= nil)
end

local UNKNOWN_WORD = -12
local UNKNOWN_CHAR = -12

-- log10 P(w)
function M.p_word(w)
  ensure()
  if not words or not token then return UNKNOWN_WORD end
  local f = words[w]
  if not f or f <= 0 then return UNKNOWN_WORD end
  return LOG10(f) - LOG10(token.total_words)
end

-- 字级 token 概率（不带「独立成词」折扣，用于整句逐字路径打分）
function M.p_char_token(ch)
  ensure()
  if not token then return UNKNOWN_CHAR end
  local f = token.chars and token.chars[ch]
  if not f or f <= 0 then return UNKNOWN_CHAR end
  return LOG10(f) - LOG10(token.total_chars)
end

-- 字二元：log10 P(下一个字 | 上一个字)；没有记录返回 nil
-- 默认关闭：数据 1.5MB、首次加载约 300ms，而实测在现有评测集上未见量化提升。
-- 需要时把 schema 的 segment_phrase/char_bigram 改 true（会惰性加载 char_bigram.lua）。
local CHAR_BIGRAM_ENABLE = false
local char_bigram = nil
local char_bigram_checked = false
function M.set_char_bigram(v) CHAR_BIGRAM_ENABLE = (v ~= false) end
function M.p_char_bigram(prev_ch, ch)
  if not CHAR_BIGRAM_ENABLE then return nil end
  if os.getenv('NO_CHAR_BIGRAM') then return nil end
  if not prev_ch or prev_ch == '' or not ch or ch == '' then return nil end
  if not char_bigram_checked then
    char_bigram_checked = true
    local ok, v = pcall(require, 'char_bigram')
    if ok and type(v) == 'table' then char_bigram = v end
  end
  if not char_bigram then return nil end
  local n = char_bigram.pairs[prev_ch .. '\t' .. ch]
  if not n or n <= 0 then return nil end
  return LOG10(n) - LOG10(char_bigram.total)
end

-- 单字作为「独立词」的比例：字 token 频率包含它在多字词里的出现，
-- 直接当词概率会严重高估（导致句子解码倾向拆字）。取经验比例 12%。
local STANDALONE_RATIO = 0.12

-- log10 P(w)，词表缺失时用兜底频次（如词组索引里的 sf）
function M.p_word_fallback(w, fb)
  ensure()
  if not words or not token then return UNKNOWN_WORD end
  local f = words[w]
  if (not f or f <= 0) then f = fb end
  if not f or f <= 0 then return UNKNOWN_WORD end
  return LOG10(f) - LOG10(token.total_words)
end

-- log10 P(ch)（单字词概率 ≈ 字 token 频率 × 独立成词比例）
function M.p_char(ch)
  ensure()
  if not token then return UNKNOWN_CHAR end
  local f = token.chars and token.chars[ch]
  if not f or f <= 0 then return UNKNOWN_CHAR end
  return LOG10(f) - LOG10(token.total_chars) + LOG10(STANDALONE_RATIO)
end

-- 离线 bigram 的调和分母缓存（按列表长度）
local harmonic = {}
local function harmonic_sum(n)
  local z = harmonic[n]
  if z then return z end
  z = 0
  for j = 1, n do z = z + 1 / (j + 1) end
  harmonic[n] = z
  return z
end

-- 上下文相对分：log10(P(w|prev) / P_uniform)，无信息返回 nil
function M.p_ctx(prev, w, env)
  if not prev or prev == '' or not w or w == '' then return nil end
  -- 1) 用户 bigram（真实计数）
  local prob, n_follow = nil, 0
  if ngram_ref and type(ngram_ref.pair_prob_norm) == 'function' then
    local ok, v, n = pcall(ngram_ref.pair_prob_norm, prev, w, env)
    if ok and v then
      prob = v
      n_follow = n or 0
      if prob > 0 then return LOG10(prob) end
    end
  end
  -- 2) 离线 bigram 表（只有排名）
  local nb = next_big and next_big[prev]
  if nb then
    local N = #nb
    if N > 0 then
      for i = 1, N do
        if nb[i] == w then
          local p = (1 / (i + 1)) / harmonic_sum(N)
          return LOG10(p * N)
        end
      end
    end
  end
  return nil
end

return M
