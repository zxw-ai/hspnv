-- BG5 learning v10: 真正符合用户直觉的动态笔画分词与自学习系统
-- 核心体验保障：
-- 1. 点分词键（按 1 次 '）：严格锁定两字词组，按首字+次字笔顺顺序精准匹配；
-- 2. 点 2 次分词键：严格锁定三字词组；点 3 次：严格锁定四字词组；
-- 3. 刚按分词键（如 1324454'）：绝不卡顿、绝不空白，立刻推荐该字开头的两字高频词（如“还是”）；
-- 4. 笔画顺序完全匹配（exact）：无条件稳居第一位；
-- 5. 纯净度保障：绝无任何阿拉伯数字或编码注释。

local index = require('index')
local words = require('words')
local stroke = require('stroke')
local learning = require('learning')
-- 容错加载 ngram：即使 ngram 模块缺失/加载失败，也绝不影响笔画输入主流程
local ok_ngram, ngram = pcall(require, 'ngram')
if not ok_ngram then
  ngram = {
    attach = function() return true end,
    word_freq = function() return 0 end,
    char_freq = function() return 0 end,
  }
end
local head_words = require('head_words')
local phrase_stroke_index = require('phrase_stroke_index')
local next_words = require('next_words')
local next_words_big = require('next_words_big')
local next_words_tri = require('next_words_tri')
local auto_segment = require('auto_segment')
local phrase_assoc = require('phrase_assoc')
local phrase_assoc_tri = require('phrase_assoc_tri')
local phrase_assoc_quad = require('phrase_assoc_quad')
local unigram_fallback = require('unigram_fallback')

-- 用户频次权重步长（调整排序平衡）：
-- WORD_UF_STEP：词候选排序中，用户上屏 1 次 ≈ 词库词频 30000（原 100000，避免一次误选就霸榜）
-- CHAR_UF_STEP：单字候选排序中，用户上屏 1 次 ≈ 静态字频 5000（原直接相加，权重过低，个性化不足）
-- =============================================================================
-- 候选重排权重表（路线4：排序流水线显式化，借鉴讯飞 ResultScore/ResultSort 分层）
-- 所有排序因子统一收敛到本表，后续调优只改这里：
--   uf_step      词级：用户上屏 1 次 ≈ 静态词频的步长
--   char_uf_step 字级：用户上屏 1 次 ≈ 静态字频的步长
--   connector    衔接词固定加分（键道「衔接词优先」）
--   sf_generic   通用后接词兜底分（无历史时的常用起句词）
--   sf_bigram    离线 bigram 预测分（next_words_big/next_words）
--   sf_assoc      高频短语/句子联想分（phrase_assoc）
--   sf_open      分词后开放联想分（emit_open_continuation）
--   sf_tri       三连联想分（连续上屏两词后，next_words_tri/phrase_assoc_tri）
--   sf_quad       四连联想分（phrase_assoc_quad）
--   sf_tailword  末尾字组词联想分
-- =============================================================================
local WEIGHTS = {
  uf_step      = 30000,
  char_uf_step = 5000,
  connector    = 20000,
  sf_generic   = 200000,
  sf_bigram    = 300000,
  sf_assoc     = 450000,
  sf_open      = 520000,
  sf_tri       = 500000,
  sf_quad      = 550000,
  sf_tailword  = 150000,
}
local WORD_UF_STEP = WEIGHTS.uf_step
local CHAR_UF_STEP = WEIGHTS.char_uf_step
-- 分词联想上限：预编辑区超过 N 个分词符时不再联想更长词（防爆上限）
local MAX_WORD_LEN = 8

-- 共享模块表：挂到 env 供其他模块（如 predict_space）复用同一实例（避免 require 隔离）
local M = {}

local MAX_PREFIX = 96
local MAX_STATES = 8000
local MAX_OUTPUT = 150

local attached = setmetatable({}, { __mode = 'k' })
local cache = setmetatable({}, { __mode = 'k' })
local cache_rev = setmetatable({}, { __mode = 'k' })

-- 候选层级：单笔画符号顶格；普通字与词语先出；部件/部首仅完整笔顺后出现。
local STROKE_SYMBOLS = { ["一"] = true, ["丨"] = true, ["丿"] = true, ["丶"] = true, ["乙"] = true }
local PRIORITY_COMPONENTS = {}
for ch in ("一丨丿丶乙氵亻艹扌辶讠纟饣忄阝宀疒礻衤钅彳犭夂攵冖冂勹匚廴彡卩厶巛灬爫户戈攴疋癶缶聿艮豸"):gmatch("[\1-\127\194-\244][\128-\191]*") do
  PRIORITY_COMPONENTS[ch] = true
end
-- 模糊笔画：开启后「折(5) ≈ 竖(2)」容错（常见笔顺混淆）。
-- 用于完整码精确匹配与词匹配（prefix_match）；前缀 Trie 桶保持严格匹配以控制候选噪音。
local fuzzy_stroke_on = false
local fuzzy_exact_stroke = {}
for ch, code in pairs(stroke) do
  local key = code:gsub("[25]", "X")
  local list = fuzzy_exact_stroke[key]
  if not list then
    list = {}
    fuzzy_exact_stroke[key] = list
  end
  list[#list + 1] = ch
end
local function fuzzy_code(s)
  if not fuzzy_stroke_on then return s end
  return s:gsub("[25]", "X")
end

-- =============================================================================
-- 局部纠错表（路线3，借鉴讯飞 add_cor_in_segment 音节段纠错）：
-- 只对「高频易混笔画对」做单位置替换纠错，作为全局模糊笔画（fuzzy_stroke）的补充。
-- 与全局模糊的区别：
--   fuzzy_stroke：把整码 2/5 统一归一（候选集变大，噪音较多）
--   correction  ：只生成"把某一位替换成易混笔画"的变体码，命中字以 rank=1500
--                 （精确 0 < 纠错 1500 < 前缀桶 2000+）插入候选，精确码永远优先。
-- 可通过 schema option correction_stroke 开关（默认开），与 fuzzy_stroke 并存。
-- =============================================================================
local CORRECTION_PAIRS = {
  { "2", "5" }, { "5", "2" },  -- 竖 2 ↔ 折 5（最高频混淆）
  { "3", "4" }, { "4", "3" },   -- 撇 3 ↔ 点 4（次高频）
}
local correction_stroke_on = true

-- 生成 seg 的所有「单位置易混替换」变体码（去重）
local function correction_variants(seg)
  local chars = {}
  for ch in seg:gmatch("[12345]") do
    chars[#chars + 1] = ch
  end
  if #chars < 2 then return {} end
  local variants = {}
  local seen = {}
  for i, ch in ipairs(chars) do
    for _, pair in ipairs(CORRECTION_PAIRS) do
      if ch == pair[1] then
        local clone = {}
        for j = 1, #chars do clone[j] = chars[j] end
        clone[i] = pair[2]
        local v = table.concat(clone)
        if not seen[v] then
          seen[v] = true
          variants[#variants + 1] = v
        end
      end
    end
  end
  return variants
end

-- 笔画前缀匹配：支持通配符 ?（匹配任意一笔 1-5）
local function prefix_match(code, part)
  if not code then return false end
  if not part:find("?", 1, true) then
    local c, p = fuzzy_code(code), fuzzy_code(part)
    return c:sub(1, #p) == p
  end
  local pat = "^" .. part:gsub("%?", "[12345]")
  return code:match(pat) ~= nil
end

local function complete_component(ch, code, input)
  return PRIORITY_COMPONENTS[ch] and code and not input:find("?", 1, true)
    and code == input
end

-- 精确码倒排（常驻，极小）：完整笔顺直接命中单字
local exact_stroke = {}
-- 单字词频：由 index 高频表累计，用于前缀候选按常用度排序，保证「暴」「露」这类常用字在短码下也能进入候选池
local char_freq = {}
for _, list in pairs(index) do
  for _, item in ipairs(list) do
    local ch = item[1]
    char_freq[ch] = (char_freq[ch] or 0) + (item[2] or 0)
  end
end
for ch, code in pairs(stroke) do
  local list = exact_stroke[code]
  if not list then
    list = {}
    exact_stroke[code] = list
  end
  list[#list + 1] = ch
end

-- Trie 增量桶（iOS 式按需构建 + LRU 即弃）：
-- 只预构建 1-5 首笔桶，后续每笔从父桶过滤（O(父桶大小)，<1ms），
-- 缓存上限 1024 个桶，远大于单次输入链，几乎不会触发全量重建；内存占用始终 <1MB。
-- 预排序字符表：全量重建时直接按词频序遍历，免去每次排序，彻底消除首字重建卡顿。
local sorted_chars = {}
for ch in pairs(stroke) do
  sorted_chars[#sorted_chars + 1] = ch
end
table.sort(sorted_chars, function(a, b)
  return (char_freq[a] or 0) > (char_freq[b] or 0)
end)
local bucket_cache = {}
local BUCKET_CACHE_MAX = 1024
local function build_bucket_full(seg)
  -- 全量返回（预排序），父桶过滤才能逐级保留低频常用字（如「审」在 4 前缀 300 名外也必须进入 44 桶）
  local arr = {}
  for _, ch in ipairs(sorted_chars) do
    local code = stroke[ch]
    if code and code:sub(1, #seg) == seg then
      arr[#arr + 1] = ch
    end
  end
  return arr
end
local function get_bucket(seg)
  if not seg or seg == '' then return {} end
  local cached = bucket_cache[seg]
  if cached then return cached end
  local parent = seg:sub(1, -2)
  local parent_bucket = bucket_cache[parent]
  local bucket
  if parent_bucket then
    -- 从父桶过滤，保持词频顺序（Trie 增量，极快）
    bucket = {}
    for _, ch in ipairs(parent_bucket) do
      local code = stroke[ch]
      if code and code:sub(1, #seg) == seg then
        bucket[#bucket + 1] = ch
      end
    end
  else
    bucket = build_bucket_full(seg)
  end
  local n = 0
  for _ in pairs(bucket_cache) do n = n + 1 end
  if n >= BUCKET_CACHE_MAX then
    bucket_cache = {}
  end
  bucket_cache[seg] = bucket
  return bucket
end
-- 预构建 1-5 首笔桶，保证第一笔输入零卡顿
for i = 1, 5 do
  get_bucket(tostring(i))
end

-- 词组切片索引：首字 → 以该字开头的全部词组（2字/3字/4字/5字+）。
-- 只索引 #w 为 3 的倍数的词（全部为三字节汉字，扩展字极罕见跳过，不影响常用词）。
-- 不排序：命中词在检索时按词频即时排序，命中通常很少，排序开销可忽略。
local char_words = {}
-- 仅为双字词建立第二字 1/2 笔前缀索引：覆盖最常用短码，避免运行时扫描全部词桶。
-- 索引保存已有词字符串引用，不复制文本；三字以上仍走通用桶，控制内存。
local pair_prefix_index = {}
-- 短码首字检索本身只遍历高频首字前 120 个；其余首字保留通用桶，避免无效常驻索引。
local indexed_first = {}
for i = 1, math.min(#sorted_chars, 120) do
  indexed_first[sorted_chars[i]] = true
end
for w, sf in pairs(words) do
  local n = #w
  if n >= 6 and n % 3 == 0 then
    local first = w:sub(1, 3)
    local bucket = char_words[first]
    if not bucket then
      bucket = {}
      char_words[first] = bucket
    end
    bucket[#bucket + 1] = w
    if n == 6 and indexed_first[first] then
      local second = w:sub(4, 6)
      local code = stroke[second]
      if code then
        local by_prefix = pair_prefix_index[first]
        if not by_prefix then
          by_prefix = {}
          pair_prefix_index[first] = by_prefix
        end
        for plen = 1, math.min(2, #code) do
          local p = code:sub(1, plen)
          local list = by_prefix[p]
          if not list then
            list = {}
            by_prefix[p] = list
          end
          list[#list + 1] = w
        end
      end
    end
  end
end

-- 惰性排序缓存：只在词组桶首次访问某首字时对该桶按词频排序一次并缓存。
-- 避免冷启动全量排序（+3.6s），同时保证每桶取词时高频词（审查/第一等）排前面。
local char_words_sorted = {}
local function get_sorted_bucket(first_ch)
  local sorted = char_words_sorted[first_ch]
  if sorted then return sorted end
  local raw = char_words[first_ch]
  if not raw or #raw == 0 then return nil end
  table.sort(raw, function(a, b)
    return (words[a] or 0) > (words[b] or 0)
  end)
  char_words_sorted[first_ch] = raw
  return raw
end

-- 词组桶 LRU 缓存：按「每字笔画前缀」直接命中词库词组（支持任意字数）。
-- 按下分词键时优先调用本桶；同一编码重复输入 O(1) 命中；缓存上限 64，超过即弃，内存始终极小。
local phrase_cache = {}
local PHRASE_CACHE_MAX = 64
-- 检查词 w（nchars 字）是否每一段的笔画前缀都与 parts 匹配
local function phrase_match(w, parts, nchars, start_part, wild_patterns)
  local ok = true
  for i = start_part or 1, nchars do
    local c = stroke[w:sub((i - 1) * 3 + 1, i * 3)]
    local part = parts[i]
    local matched
    if wild_patterns and wild_patterns[i] then
      matched = c and c:match(wild_patterns[i]) ~= nil
    else
      matched = prefix_match(c, part)
    end
    if not matched then
      ok = false
      break
    end
  end
  return ok
end
local function slice_phrase_bucket(parts)
  local key = table.concat(parts, "'")
  local cached = phrase_cache[key]
  if cached then return cached end
  local hits = {}
  local nchars = #parts
  local want_len = nchars * 3
  local wild_patterns = {}
  for i, part in ipairs(parts) do
    if part:find("?", 1, true) then
      wild_patterns[i] = "^" .. part:gsub("%?", "[12345]")
    end
  end
  local seen_first = {}
  local function collect(first_ch, is_exact)
    if seen_first[first_ch] then return end
    seen_first[first_ch] = true
    -- 先匹配再排序命中结果，避免对无关词组做整桶排序。
    -- 双字词且第二段为 1/2 笔短码时，直接命中惰性前缀索引；其余仍走完整桶。
    local bucket = char_words[first_ch]
    local indexed_pair = false
    -- 首笔确定、第二笔任意（如 1?）可复用第一笔索引；
    -- ?1、1?? 等无法安全复用的模式仍回退完整桶，确保不漏词。
    if nchars == 2 and #parts[2] <= 2 then
      local prefix_key = parts[2]
      local first_stroke = prefix_key:match("^([1-5])%?$")
      if first_stroke then prefix_key = first_stroke end
      if not prefix_key:find("?", 1, true) then
        local by_prefix = pair_prefix_index[first_ch]
        if by_prefix and by_prefix[prefix_key] then
          bucket = by_prefix[prefix_key]
          indexed_pair = true
        end
      end
    end
    if bucket then
      local limit = #bucket
      if indexed_pair then
        -- 索引桶只含双字词，且首字已由桶键验证。
        for idx = 1, limit do
          local w = bucket[idx]
          if phrase_match(w, parts, nchars, 2, wild_patterns) then hits[#hits + 1] = w end
        end
      else
        for idx = 1, limit do
          local w = bucket[idx]
          if #w == want_len and phrase_match(w, parts, nchars, 2) then
            hits[#hits + 1] = w
          end
        end
      end
    end
  end
  -- 1. 精确首字优先（全码输入时目标首字必在 exact_stroke 中，保证全量词库 100% 无遗漏命中）
  local exact_first = exact_stroke[parts[1]]
  if exact_first then
    for _, ch in ipairs(exact_first) do
      collect(ch, true)
    end
  end
  -- 2. 再遍历前缀桶高频首字（短码/前缀输入；限制前 120 字，每桶取前 30 高频词，兼顾召回与性能）
  local first_chars = get_bucket(parts[1])
  if first_chars then
    local limit = math.min(#first_chars, 120)
    for i = 1, limit do
      collect(first_chars[i], false)
    end
  end
  local n = 0
  for _ in pairs(phrase_cache) do n = n + 1 end
  if n >= PHRASE_CACHE_MAX then
    phrase_cache = {}
  end
  -- 只保留真实词频最高的 120 个，避免先对超大命中集全量排序。
  local K = 120
  local top_hits = {}
  local function score(w) return words[w] or 0 end
  local function sift_up(i)
    while i > 1 do
      local p = math.floor(i / 2)
      if score(top_hits[p]) <= score(top_hits[i]) then break end
      top_hits[p], top_hits[i] = top_hits[i], top_hits[p]
      i = p
    end
  end
  local function sift_down(i)
    while true do
      local l, r = i * 2, i * 2 + 1
      local m = i
      if l <= #top_hits and score(top_hits[l]) < score(top_hits[m]) then m = l end
      if r <= #top_hits and score(top_hits[r]) < score(top_hits[m]) then m = r end
      if m == i then break end
      top_hits[m], top_hits[i] = top_hits[i], top_hits[m]
      i = m
    end
  end
  for _, w in ipairs(hits) do
    if #top_hits < K then
      top_hits[#top_hits + 1] = w
      sift_up(#top_hits)
    elseif score(w) > score(top_hits[1]) then
      top_hits[1] = w
      sift_down(1)
    end
  end
  table.sort(top_hits, function(a, b) return score(a) > score(b) end)
  phrase_cache[key] = top_hits
  return top_hits
end

local function init(env)
  -- 挂到 env.engine（所有 Lua 组件共享同一 engine）供 predict_space 等复用同一实例
  if env.engine then
    env.engine.bg5_segment_phrase = M
  end
  env.bg5_segment_phrase = M  -- 兼容旧引用
  if not attached[env] then
    learning.attach(env)
    ngram.attach(env)
    attached[env] = true
    cache[env] = {}
    cache_rev[env] = learning.revision()
  end
end

local function utf8_chars(s)
  local t = {}
  if not s then return t end
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    t[#t + 1] = ch
  end
  return t
end

-- 快速 UTF-8 前两字提取（按字节数直接定位，比 gmatch 快数倍，用于构建 20 万双字词索引）
local function utf8_first_two(w)
  local b1 = w:byte(1)
  if not b1 then return nil, nil end
  local l1 = (b1 < 0x80) and 1 or (b1 < 0xE0) and 2 or (b1 < 0xF0) and 3 or 4
  local c1 = w:sub(1, l1)
  local rest = w:sub(l1 + 1)
  if rest == "" then return c1, nil end
  local b2 = rest:byte(1)
  local l2 = (b2 < 0x80) and 1 or (b2 < 0xE0) and 2 or (b2 < 0xF0) and 3 or 4
  return c1, rest:sub(1, l2)
end

local function utf8_first_char(s)
  if not s or s == '' then return nil end
  return s:match("^[\1-\127\194-\244][\128-\191]*")
end

local function to_stroke_symbol(s)
  if not s then return "" end
  -- 分词符 ' 必须保留（讯飞式：词组未上屏前，分词符一直显示在笔画串中）
  return s:gsub("1", "一"):gsub("2", "丨"):gsub("3", "丿"):gsub("4", "丶"):gsub("5", "乛"):gsub("[^一丨丿丶乛']", "？")
end

local function make_candidate(type, start, _end, text, raw_input)
  local c = Candidate(type, start, _end, text, '')
  local preedit = raw_input or ''
  local s, e = tonumber(start), tonumber(_end)
  if s and e and s >= 0 and e >= s and e <= #preedit then
    preedit = preedit:sub(s + 1, e)
  end
  c.preedit = to_stroke_symbol(preedit)
  return c
end

-- 笔画前缀匹配：支持通配符 ?（匹配任意一笔 1-5）
local function add_unique(out, seen, ch, exact, rank, component)
  if not seen[ch] then
    seen[ch] = exact and 2 or 1
    out[#out + 1] = {ch = ch, exact = exact, stroke_symbol = STROKE_SYMBOLS[ch] or false, component = component or false, rank = rank or 999999}
  else
    for _, item in ipairs(out) do
      if item.ch == ch then
        if exact then
          seen[ch] = 2
          item.exact = true
        end
        if component then item.component = true end
        break
      end
    end
  end
end

local function chars_for(seg, env)
  if not seg or seg == '' then return {} end
  local rev = learning.revision()
  if cache_rev[env] ~= rev then
    cache[env] = {}
    cache_rev[env] = rev
  end

  local saved = cache[env][seg]
  if saved then return saved end

  local out, seen = {}, {}
  local function add_char(ch, exact, rank)
    local is_component = PRIORITY_COMPONENTS[ch] and not STROKE_SYMBOLS[ch]
    if is_component and stroke[ch] ~= seg then return end
    add_unique(out, seen, ch, exact, rank, is_component or false)
  end

  -- 0. 通配检索：段内含 ? 时，? 匹配任意一笔（1-5），全量扫描命中所有可能字
  if seg:find("?", 1, true) then
    local pat = "^" .. seg:gsub("%?", "[12345]")
    for ch, code in pairs(stroke) do
      if code and code:match(pat) then
        if not PRIORITY_COMPONENTS[ch] then
          add_unique(out, seen, ch, false, 3000)
        end
      end
    end
    local last = learning.get_last_commit() or ''
    table.sort(out, function(a, b)
      if a.component ~= b.component then return a.component end
      local af, bf = learning.freq(a.ch, env), learning.freq(b.ch, env)
      local acf, bcf = ngram.char_freq(last, a.ch, env), ngram.char_freq(last, b.ch, env)
      if af * CHAR_UF_STEP + acf ~= bf * CHAR_UF_STEP + bcf then return af * CHAR_UF_STEP + acf > bf * CHAR_UF_STEP + bcf end
      local af2, bf2 = char_freq[a.ch] or 0, char_freq[b.ch] or 0
      if af2 ~= bf2 then return af2 > bf2 end
      if a.rank ~= b.rank then return a.rank < b.rank end
      return a.ch < b.ch
    end)
    cache[env][seg] = out
    return out
  end

  -- 1. O(1) 直取完整笔顺完全匹配的单字，彻底消灭 10117 次循环全表遍历！
  local exact_list
  if fuzzy_stroke_on then
    exact_list = fuzzy_exact_stroke[fuzzy_code(seg)]
  else
    exact_list = exact_stroke[seg]
  end
  if exact_list then
    for _, ch in ipairs(exact_list) do
      add_char(ch, true, 0)
    end
  end

  -- 1.5 局部纠错候选（路线3）：易混笔画单位置替换的精确命中字，作为补充
  -- rank=1500：精确(0) < 纠错(1500) < 普通前缀桶(2000+)，精确码永远优先。
  if correction_stroke_on then
    local variants = correction_variants(seg)
    for _, var in ipairs(variants) do
      local corr_list = exact_stroke[var]
      if corr_list then
        for _, ch in ipairs(corr_list) do
          add_char(ch, false, 1500)
        end
      end
    end
  end

  -- 2. 注入用户在当前前缀下学习过的字（上屏频次优先）
  for ch, cnt in pairs(learning.all_chars(env)) do
    local code = stroke[ch]
    if code and (fuzzy_code(code) == fuzzy_code(seg) or fuzzy_code(code):sub(1, #seg) == fuzzy_code(seg)) then
      add_char(ch, fuzzy_code(code) == fuzzy_code(seg), 0)
    end
  end

  -- 只有完整笔顺输入时才注入偏旁/部首；前缀阶段不抢普通高频字位置。
  for ch in pairs(PRIORITY_COMPONENTS) do
    local code = stroke[ch]
    if complete_component(ch, code, seg) then
      add_unique(out, seen, ch, true, 900000, true)
    end
  end

  -- 3. Trie 增量桶（主索引）：按词频排序的完整切片，任何中间笔顺和低频常用字都能命中！
  local bucket = get_bucket(seg)
  if bucket then
    for i, ch in ipairs(bucket) do
      if i > MAX_PREFIX then break end
      local code = stroke[ch]
      local exact = code == seg
      add_char(ch, exact, 2000 + i)
    end
  end

  -- 4. 兜底：若全量切片缺失，回退 index 高频表
  local indexed = index[seg]
  if indexed and #out == 0 then
    for i = 1, math.min(#indexed, MAX_PREFIX) do
      local item = indexed[i]
      local ch = item[1]
      add_char(ch, false, i)
    end
  end

  local last = learning.get_last_commit() or ''
  table.sort(out, function(a, b)
    if a.stroke_symbol ~= b.stroke_symbol then return a.stroke_symbol end
    if a.component ~= b.component then return not a.component end
    if a.exact ~= b.exact then return a.exact end
    local af, bf = learning.freq(a.ch, env), learning.freq(b.ch, env)
    local acf, bcf = ngram.char_freq(last, a.ch, env), ngram.char_freq(last, b.ch, env)
    if af * CHAR_UF_STEP + acf ~= bf * CHAR_UF_STEP + bcf then return af * CHAR_UF_STEP + acf > bf * CHAR_UF_STEP + bcf end
    -- 完整部件只在完整编码后出现；普通字与学习频次先参与排序。
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.ch < b.ch
  end)

  cache[env][seg] = out
  return out
end

-- 单字及无分词高频词组联想输出（输入笔画时，单字优先，高频词组紧随其后）
local function emit_single(input, seg, env)
  local chars = chars_for(input, env)

  -- 笔画打多时的最长前缀容错兜底：绝不返回 0 候选，绝不把原始数字暴露在屏幕上！
  -- 回退时过滤偏旁部首：超过完整码后不得让部首重新出现。
  if #chars == 0 and #input > 1 then
    for l = #input - 1, 1, -1 do
      local sub_chars = chars_for(input:sub(1, l), env)
      local filtered = {}
      for _, item in ipairs(sub_chars) do
        if not item.component then filtered[#filtered + 1] = item end
      end
      if #filtered > 0 then
        chars = filtered
        break
      end
    end
  end

  -- 候选层级：单笔画顶格 → 完全码偏旁部首 → 完全码普通字 → 其他高频字（无分词时只出单字，不出多字词）
  local emitted = 0
  local symbols, comp_exacts, exacts, others = {}, {}, {}, {}
  for _, item in ipairs(chars) do
    if item.stroke_symbol then
      symbols[#symbols + 1] = item.ch
    elseif item.exact and item.component then
      comp_exacts[#comp_exacts + 1] = item.ch
    elseif item.exact then
      exacts[#exacts + 1] = item.ch
    else
      others[#others + 1] = item.ch
    end
  end

  -- 1. 单笔画符号顶格输出。
  for _, ch in ipairs(symbols) do
    yield(make_candidate('single', seg.start, seg._end, ch, input))
    emitted = emitted + 1
  end

  -- 2. 完全码命中的偏旁部首优先显示。
  for _, ch in ipairs(comp_exacts) do
    yield(make_candidate('single', seg.start, seg._end, ch, input))
    emitted = emitted + 1
  end

  -- 3. 完全码命中的普通字。
  for _, ch in ipairs(exacts) do
    yield(make_candidate('single', seg.start, seg._end, ch, input))
    emitted = emitted + 1
  end

  -- 4. 其他高频字（最多补足 9 个普通字展示位）。
  for _, ch in ipairs(others) do
    if emitted >= 9 + #exacts + #comp_exacts + #symbols then break end
    yield(make_candidate('single', seg.start, seg._end, ch, input))
    emitted = emitted + 1
  end

end

-- 统一判断一个词是否与 parts 每一段完全匹配完整笔顺
local function is_phrase_exact(w, parts)
  local chs = utf8_chars(w)
  if #chs ~= #parts then return false end
  for i, ch in ipairs(chs) do
    local code = stroke[ch]
    if not code or code ~= parts[i] then
      return false
    end
  end
  return true
end

-- 无整词命中时的部分回退：保护分词符前已命中的词 + 末段以笔画重新定字（不用整串笔画兜底）
local function fallback_partial(parts, raw_input, seg, env)
  local emitted = 0
  -- 标记部分回退模式：filter_seg_count 见此后不再按完整词长过滤（放行前段词/末段单字）
  if env and env.engine then
    env.engine._bg5_fallback = true
  end
  -- 1. 前段已命中的词优先保护输出（多级回退：从长到短尝试，找到最长已命中前缀即停）
  --    末尾是分词符（如 亡码'羊码'补码'）→ 候选前缀从 全部段 开始逐级缩短；
  --    末尾是进行中的笔画（如 亡码'羊码'4）→ 候选前缀从 去掉末段 开始逐级缩短。
  local tail_is_sep = raw_input:sub(-1, -1) == "'"
  local max_prev = tail_is_sep and #parts or (#parts - 1)
  for plen = max_prev, 1, -1 do
    local prev_parts = {}
    for i = 1, plen do prev_parts[i] = parts[i] end
    local seen_prev = {}
    local prev_emitted = false
    -- 单段前段（前一个字的完整码）：只输出 1 个代表字（优先精确字，如「麻」），
    -- 避免同码字（麻/摩/磨/魔…）占满候选区，把末段定字挤到后面。
    if plen == 1 then
      local prev_shown = false
      local plist = chars_for(prev_parts[1], env)
      -- 优先输出精确字（非部件）作为前段代表
      for _, item in ipairs(plist) do
        if item.exact and not item.component and not seen_prev[item.ch] then
          seen_prev[item.ch] = true
          yield(make_candidate('single', seg.start, seg._end, item.ch, raw_input))
          emitted = emitted + 1
          prev_emitted = true
          prev_shown = true
          break
        end
      end
      -- 精确字不存在时，输出第一个非部件前缀字兜底
      if not prev_shown then
        for _, item in ipairs(plist) do
          if not item.component and not seen_prev[item.ch] then
            seen_prev[item.ch] = true
            yield(make_candidate('single', seg.start, seg._end, item.ch, raw_input))
            emitted = emitted + 1
            prev_emitted = true
            break
          end
        end
      end
    else
      local prefix_prev = table.concat(prev_parts, "'")
      -- 1a. 压缩索引快速命中
      local fast_heads = phrase_stroke_index[prefix_prev]
      if fast_heads then
        for i = 1, math.min(#fast_heads, 4) do
          local w = fast_heads[i][1]
          if not seen_prev[w] then
            seen_prev[w] = true
            yield(make_candidate('phrase', seg.start, seg._end, w, raw_input))
            emitted = emitted + 1
            prev_emitted = true
          end
        end
      end
      -- 1b. 词库桶精确匹配（保证「亡羊」等普通词能保留在候选区）
      local bucket_hits = slice_phrase_bucket(prev_parts)
      for i = 1, math.min(#bucket_hits, 4) do
        local w = bucket_hits[i]
        if not seen_prev[w] then
          seen_prev[w] = true
          yield(make_candidate('phrase', seg.start, seg._end, w, raw_input))
          emitted = emitted + 1
          prev_emitted = true
        end
      end
    end
    if prev_emitted then break end
  end
  -- 2. 末段以笔画重新定字（单字候选，独立计数不受前段词数量影响，最多 6 个）
  local last_part = parts[#parts]
  if last_part then
    local clist = chars_for(last_part, env)
    local exacts, others = {}, {}
    for _, item in ipairs(clist) do
      if item.exact then
        exacts[#exacts + 1] = item.ch
      elseif not item.component then
        others[#others + 1] = item.ch
      end
    end
    local tail_emitted = 0
    for _, ch in ipairs(exacts) do
      yield(make_candidate('single', seg.start, seg._end, ch, raw_input))
      emitted = emitted + 1
      tail_emitted = tail_emitted + 1
    end
    for _, ch in ipairs(others) do
      if tail_emitted >= 6 then break end
      yield(make_candidate('single', seg.start, seg._end, ch, raw_input))
      emitted = emitted + 1
      tail_emitted = tail_emitted + 1
    end
  end
  -- 3. 极端情况（前段无词、末段无字）才输出笔画符号兜底
  if emitted == 0 then
    local sym = to_stroke_symbol(raw_input)
    yield(make_candidate('single', seg.start, seg._end, sym, raw_input))
  end
end

-- 词库前缀预测：在 char_words 全量词库桶中查找「前 #parts 段完整匹配、总字数为 target_len」的词（如 亡羊补 + 1 段 → 亡羊补牢），按词频排序取前 3
local function phrase_prefix_hits(parts, target_len)
  local hits = {}
  local seen = {}
  local head_chars = exact_stroke[parts[1]]
  if not head_chars then return hits end
  for _, head in ipairs(head_chars) do
    local bucket = char_words[head] or {}
    for _, w in ipairs(bucket) do
      if not seen[w] then
        local chs = utf8_chars(w)
        if #chs == target_len then
          local ok = true
          for i, p in ipairs(parts) do
            local ch = chs[i]
            local code = ch and stroke[ch]
            if not code or code ~= p then
              ok = false
              break
            end
          end
          if ok then
            seen[w] = true
            hits[#hits + 1] = w
          end
        end
      end
    end
  end
  -- 按词频排序，返回最多 3 个最常用的预测词
  table.sort(hits, function(a, b) return (words[a] or 0) > (words[b] or 0) end)
  local out = {}
  for i = 1, math.min(#hits, 3) do out[i] = hits[i] end
  return out
end

-- 动态分词组词输出：target_len 严格按分词次数锁定
-- full_len: Rime 分段模式下传入完整输入长度（用于跨段词组候选的 end）；不分段时传 nil
local function emit_phrase_with_parts(parts, target_len, raw_input, seg, env, full_len)
  -- 防爆上限：超过 MAX_WORD_LEN 的分词不再尝试匹配超长词（词库机构名等长词保留但不在此路径联想）
  if target_len > MAX_WORD_LEN then return end
  -- 说明：即使末段是"进行中的前缀"（如 4/45），也先尝试找词/前缀词匹配；
  -- 找不到词时由下方 order 空分支的 fallback_partial 保护前段词+末段定字。
  local found = {}
  local last = learning.get_last_commit() or ''

  local function add_cand(w, sf)
    local chs = utf8_chars(w)
    if #chs ~= target_len then return end
    local exact = is_phrase_exact(w, parts)
    local uf = learning.freq(w, env)
    local cf = ngram.word_freq(last, w, env)
    local old = found[w]
    if not old or (exact and not old.exact) or ((uf * WORD_UF_STEP + cf) > (old.uf * WORD_UF_STEP + (old.cf or 0))) then
      found[w] = {text = w, sf = sf or 0, uf = uf, cf = cf, exact = exact}
    end
  end

  -- 1. 词组精确桶：完整编码 O(1) 命中（分词后最高优先级，只检索词库词条）
  local has_phrase = false
  local fast_key = table.concat(parts, "'")
  local fast_list = phrase_stroke_index[fast_key]
  if fast_list then
    has_phrase = true
    for _, item in ipairs(fast_list) do
      add_cand(item[1], item[2])
    end
  end
  -- 2. 词组切片桶：按「每字笔画前缀」直接命中词库词组（任意字数，分词后第一优先级，LRU 缓存）
  local slice_hits = slice_phrase_bucket(parts)
  if #slice_hits > 0 then
    has_phrase = true
    for _, w in ipairs(slice_hits) do
      add_cand(w, words[w] or 0)
    end
  end

  -- 3. 用户自造/已学词库注入（上屏学习后始终参与召回，权重按 learning 频次排序）
  for w in pairs(learning.all(env)) do
    local chs = utf8_chars(w)
    if #chs == target_len then
      local matched = true
      for i, ch in ipairs(chs) do
        local code = stroke[ch]
        local part = parts[i]
        if not code or code:sub(1, #part) ~= part then
          matched = false
          break
        end
      end
      if matched then
        add_cand(w, words[w] or 0)
      end
    end
  end

  -- 4. 词组桶全部未命中时，才走单字组合（新造词/生僻词路径，优先级最低但绝不卡死）。
  --    5 字以上词已由词组切片桶覆盖，未完成时不再跑组合（避免长词逐键卡顿）。
  local count_found = 0
  for _ in pairs(found) do count_found = count_found + 1 end
  if count_found == 0 and target_len <= 4 then
    local candidates = {}
    for i, part in ipairs(parts) do
      local c_list = chars_for(part, env)
      if #c_list == 0 and #part > 1 then
        local merged, seen2 = {}, {}
        for l = #part - 1, 1, -1 do
          local sub_c = chars_for(part:sub(1, l), env)
          for _, item in ipairs(sub_c) do
            -- 回退时过滤偏旁部首：超过完整码后不得让部首重新出现。
            if not item.component and not seen2[item.ch] then
              seen2[item.ch] = true
              merged[#merged + 1] = item
            end
          end
          if #merged >= 96 then break end
        end
        c_list = merged
      end
      candidates[i] = c_list
    end
    local per_len = 12
    if target_len == 2 then per_len = 64
    elseif target_len == 3 then per_len = 25
    elseif target_len == 4 then per_len = 16 end
    -- 状态上限：单字组合是「新造词兜底路径」，绝不能因笛卡尔积爆炸卡顿（长词未完成时也绝不卡）
    local combine_states = 0
    local DYNAMIC_COMBINE_LIMIT = 8000
    local function combine_parts(depth, cur_text)
      combine_states = combine_states + 1
      if combine_states > DYNAMIC_COMBINE_LIMIT then return end
      if depth > target_len then
        local sf = words[cur_text]
        local uf = learning.freq(cur_text, env)
        if (sf and sf > 0) or (uf and uf > 0) then
          add_cand(cur_text, sf or 0)
        end
        return
      end
      local list = candidates[depth] or {}
      local limit = math.min(#list, per_len)
      for idx = 1, limit do
        combine_parts(depth + 1, cur_text .. list[idx].ch)
      end
    end
    combine_parts(1, "")
  end

  -- 5. 多输容错：仅当某段不是任何字的前缀（用户多输错笔画）时才回退截短。
  --    全码有效时绝不截短（否则「华」全码会被截成 1 笔「3」而错误命中「我国」等词）。
  count_found = 0
  for _ in pairs(found) do count_found = count_found + 1 end
  if count_found == 0 and #parts == 2 then
    local need_fallback = false
    for _, part in ipairs(parts) do
      local exact_list = exact_stroke[part]
      local bucket = get_bucket(part)
      if (not exact_list or #exact_list == 0) and (not bucket or #bucket == 0) then
        need_fallback = true
        break
      end
    end
    if need_fallback and (#parts[2] > 2 or #parts[1] > 2) then
      local p1, p2 = parts[1], parts[2]
      for l2 = #p2, 1, -1 do
        for l1 = #p1, 1, -1 do
          local try_key = p1:sub(1, l1) .. "'" .. p2:sub(1, l2)
          local try_list = phrase_stroke_index[try_key]
          if try_list and #try_list > 0 then
            for _, item in ipairs(try_list) do
              add_cand(item[1], item[2])
            end
            break
          end
        end
        local c2 = 0
        for _ in pairs(found) do c2 = c2 + 1 end
        if c2 > 0 then break end
      end
    end
  end
  local order = {}
  for w in pairs(found) do order[#order + 1] = found[w] end

  -- 计算 raw_input 中每一段（按 ' 分隔）在整体输入中的字节偏移（0-based，供候选独立提交用）
local function compute_part_offsets(raw_input)
  local offsets = {}
  local pos = 1
  for p in raw_input:gmatch("[^']+") do
    local idx = raw_input:find(p, pos, true)
    if idx then
      -- Rime Candidate.end 是右开位置；非末段词连同其后的分隔符一起消费，
      -- 这样点选前段词后，剩余 composition 从下一段笔画开始。
      local e = idx + #p - 1
      if raw_input:sub(e + 1, e + 1) == "'" then e = e + 1 end
      offsets[#offsets + 1] = { start = idx - 1, _end = e }
      pos = idx + #p + 1
    end
  end
  return offsets
end

  -- 造词等待区词组排序：重复上屏词优先，静态词频次之，原索引顺序兜底。
  local function sort_waiting_phrases(items, env)
    table.sort(items, function(a, b)
      local au, bu = learning.freq(a.text, env) + ngram.word_freq(last, a.text, env), learning.freq(b.text, env) + ngram.word_freq(last, b.text, env)
      if au ~= bu then return au > bu end
      local as, bs = a.sf or 0, b.sf or 0
      if as ~= bs then return as > bs end
      return (a.rank or 0) < (b.rank or 0)
    end)
  end

  -- 统一候选输出：分词输入优先词库已有词组（整词/前后段词），检索不到词组时才按段序输出全码字，再其余字与完整部件。
  local function emit_all(emit_candidate, whole_phrases, waiting_items, parts, env, offsets, seg_start, seg_end)
    -- 1. 词库已有整词最优先。
    if whole_phrases then
      for _, item in ipairs(whole_phrases) do
        emit_candidate('phrase', item.text, seg_start, seg_end)
      end
    end
    -- 2. 前/后段成型词组（词库已有词组按编码匹配优先）。
    if waiting_items then
      for _, item in ipairs(waiting_items) do
        emit_candidate('phrase', item.text, item.s, item.e)
      end
    end
    -- 3. 候选区纯净：只输出 N+1 字词组候选，不输出每段单字（保持候选区干净）。
  end

  -- 容错兜底：整词不存在时，启动【造词引擎】，前段成词与后段字词全部按编码优先进入候选区！
  if #order == 0 then
    local offsets = compute_part_offsets(raw_input)
    local added = {}
    local function add_output(type, cand_text, s, e)
      s, e = s or seg.start, e or seg._end
      local key = type .. "\0" .. tostring(s) .. ":" .. tostring(e) .. "\0" .. cand_text
      if not added[key] then
        added[key] = true
        yield(make_candidate(type, s, e, cand_text, raw_input))
      end
    end

    -- 全码精确字最优先，随后是前/后段成型词组，再是其余候选字与完整部件。
    local waiting = {}
    if #parts >= 2 then
      for sub_len = 2, #parts - 1 do
        local sub_parts = {}
        for i = 1, sub_len do sub_parts[i] = parts[i] end
        local sub_key = table.concat(sub_parts, "'")
        local s = offsets[1] and offsets[1].start or seg.start
        local e = offsets[sub_len] and offsets[sub_len]._end or seg._end
        local fast_sub = phrase_stroke_index[sub_key]
        if fast_sub then
          for rank, item in ipairs(fast_sub) do waiting[#waiting + 1] = {text=item[1], sf=item[2], rank=rank, s=s, e=e} end
        end
        local sub_hits = slice_phrase_bucket(sub_parts)
        for rank, hp in ipairs(sub_hits) do waiting[#waiting + 1] = {text=hp, sf=words[hp] or 0, rank=1000+rank, s=s, e=e} end
      end
      if #parts >= 4 then
        local tail_parts = { parts[#parts - 1], parts[#parts] }
        local tail_key = table.concat(tail_parts, "'")
        local s = offsets[#parts - 1] and offsets[#parts - 1].start or seg.start
        local e = offsets[#parts] and offsets[#parts]._end or seg._end
        local fast_tail = phrase_stroke_index[tail_key]
        if fast_tail then
          for rank, item in ipairs(fast_tail) do waiting[#waiting + 1] = {text=item[1], sf=item[2], rank=rank, s=s, e=e} end
        end
        local tail_hits = slice_phrase_bucket(tail_parts)
        for rank, tp in ipairs(tail_hits) do waiting[#waiting + 1] = {text=tp, sf=words[tp] or 0, rank=1000+rank, s=s, e=e} end
      end
      sort_waiting_phrases(waiting, env)
    end
    emit_all(add_output, nil, waiting, parts, env, offsets, seg.start, seg._end)

    -- 补充输出末段完整码的精确字（如"补"）：保证 前段词+末段字 都在候选区，
    -- 也避免 Rime 因末段无候选而把预编辑区显示回原始数字。
    local last_part = parts[#parts]
    local last_exact = nil
    if fuzzy_stroke_on then
      last_exact = fuzzy_exact_stroke[fuzzy_code(last_part)]
    else
      last_exact = exact_stroke[last_part]
    end
    if last_exact then
      for _, ch in ipairs(last_exact) do
        if not PRIORITY_COMPONENTS[ch] then
          add_output('single', ch, seg.start, seg._end)
        end
      end
    end

    -- 3. 无整词时部分回退：保护前段词 + 末段按笔画重新定字（不再整串笔画兜底）
    local has_any = false
    for _ in pairs(added) do has_any = true break end
    if not has_any then
      fallback_partial(parts, raw_input, seg, env)
    end
    return
  end

  table.sort(order, function(a, b)
    if a.exact ~= b.exact then return a.exact end
    local au, bu = a.uf * WORD_UF_STEP + (a.cf or 0), b.uf * WORD_UF_STEP + (b.cf or 0)
    if au ~= bu then return au > bu end
    if a.sf ~= b.sf then return a.sf > b.sf end
    return a.text < b.text
  end)

  -- 统一候选输出：全码精确字 → 整词 → 前/后段成型词组 → 其余候选字 → 完整部件。
  local emitted_count = 0
  local added = {}
  local offsets = compute_part_offsets(raw_input)
  local function add_output(type, cand_text, s, e)
    if emitted_count >= MAX_OUTPUT then return false end
    s, e = s or seg.start, e or seg._end
    local key = type .. "\0" .. tostring(s) .. ":" .. tostring(e) .. "\0" .. cand_text
    if not added[key] then
      added[key] = true
      yield(make_candidate(type, s, e, cand_text, raw_input))
      emitted_count = emitted_count + 1
      return true
    end
    return false
  end
  local whole_phrases = {}
  for _, item in ipairs(order) do
    whole_phrases[#whole_phrases + 1] = {text=item.text}
  end
  local waiting = {}
  if #parts >= 2 then
    for sub_len = 2, #parts - 1 do
      local sub_parts = {}
      for i = 1, sub_len do sub_parts[i] = parts[i] end
      local sub_key = table.concat(sub_parts, "'")
      local s = offsets[1] and offsets[1].start or seg.start
      local e = offsets[sub_len] and offsets[sub_len]._end or seg._end
      local fast_sub = phrase_stroke_index[sub_key]
      if fast_sub then
        for rank, item in ipairs(fast_sub) do waiting[#waiting + 1] = {text=item[1], sf=item[2], rank=rank, s=s, e=e} end
      end
      local sub_hits = slice_phrase_bucket(sub_parts)
      for rank, hp in ipairs(sub_hits) do waiting[#waiting + 1] = {text=hp, sf=words[hp] or 0, rank=1000+rank, s=s, e=e} end
    end
    if #parts >= 4 then
      local tail_parts = { parts[#parts - 1], parts[#parts] }
      local tail_key = table.concat(tail_parts, "'")
      local s = offsets[#parts - 1] and offsets[#parts - 1].start or seg.start
      local e = offsets[#parts] and offsets[#parts]._end or seg._end
      local fast_tail = phrase_stroke_index[tail_key]
      if fast_tail then
        for rank, item in ipairs(fast_tail) do waiting[#waiting + 1] = {text=item[1], sf=item[2], rank=rank, s=s, e=e} end
      end
      local tail_hits = slice_phrase_bucket(tail_parts)
      for rank, tp in ipairs(tail_hits) do waiting[#waiting + 1] = {text=tp, sf=words[tp] or 0, rank=1000+rank, s=s, e=e} end
    end
    sort_waiting_phrases(waiting, env)
  end
  emit_all(add_output, whole_phrases, waiting, parts, env, offsets, seg.start, seg._end)

  -- 终极回退：如果没有任何候选，保护前段词 + 末段按笔画重新定字（不再整串笔画兜底）
  if emitted_count == 0 then
    fallback_partial(parts, raw_input, seg, env)
  end
end


-- 处理末尾按下分词键（以 ' 结尾）的通用高频连缀联想（不限字数，字词皆可连）
-- 场景1: 打出单字笔画后按分词（如 3121' 或 1324454'）-> 联想以“我”或“还”开头的所有高频短语（我们、我的、我想、还是、还有...）
-- 场景2: 打出两字词后按分词（如 31'32'）-> 联想以“我们”开头的所有高频连缀短语（我们的、我们可以、我们要...）
local function emit_open_continuation(prefix_expr, raw_input, seg, env)
  local head_candidates = {}
  -- 统一解析有效笔画段，目标词长 = 段数 + 1（第1个分词符→二字词，第2个→三字词，以此类推）
  local parts = {}
  for p in prefix_expr:gmatch("[^']+") do
    if p:match("^[12345?]+$") then parts[#parts + 1] = p end
  end
  local target_len = #parts + 1
  if prefix_expr:find("'", 1, true) then
    -- 优先 O(1) 查 phrase_stroke_index 快速获取前序词（如 "我们"）
    local fast_heads = phrase_stroke_index[prefix_expr]
    if fast_heads then
      for i = 1, math.min(#fast_heads, 8) do
        head_candidates[#head_candidates + 1] = fast_heads[i][1]
      end
    end

    -- 防爆上限：超过 MAX_WORD_LEN 段不再做超长连缀联想
    if #parts > MAX_WORD_LEN then return end
    if #parts >= 2 and #head_candidates == 0 then
      local cand_groups = {}
      for i, pt in ipairs(parts) do
        cand_groups[i] = chars_for(pt, env)
        if #cand_groups[i] == 0 then
          -- 错码后按分隔符仍须提供覆盖当前输入的笔画候选，避免原始编码回显。
          yield(make_candidate('stroke_fallback', seg.start, seg._end,
            to_stroke_symbol(raw_input), raw_input))
          return
        end
      end
      local sub_states = 0
      local function sub_dfs(depth, txt)
        if sub_states >= MAX_STATES then return end
        if depth > #parts then
          if words[txt] or learning.is_learned(txt, env) then
            head_candidates[#head_candidates + 1] = txt
          end
          return
        end
        for _, it in ipairs(cand_groups[depth]) do
          sub_states = sub_states + 1
          if sub_states > MAX_STATES then return end
          local nxt = txt .. it.ch
          if depth == #parts then
            if words[nxt] or learning.is_learned(nxt, env) then sub_dfs(depth + 1, nxt) end
          else
            sub_dfs(depth + 1, nxt)
          end
        end
      end
      sub_dfs(1, "")
    end
  else
    local clist = chars_for(prefix_expr, env)
    for i = 1, math.min(#clist, 5) do
      head_candidates[#head_candidates + 1] = clist[i].ch
    end
  end

  if #head_candidates == 0 then
    -- 无现成前缀词时：先用词库预测目标长度的整词（如输入 亡羊补' 时预测「亡羊补牢」），
    -- 再走部分回退（保护前段已命中的词 + 末段按笔画重新定字），绝不整串笔画兜底。
    local pred_hits = phrase_prefix_hits(parts, target_len)
    for i = 1, math.min(#pred_hits, 3) do
      yield(make_candidate('phrase', seg.start, seg._end, pred_hits[i], raw_input))
    end
    fallback_partial(parts, raw_input, seg, env)
    return
  end

  local found = {}
  local seen_head = {}
  local last = learning.get_last_commit() or ''
  -- 第二次分词（#parts==2）时：同时预测以两段为前缀的四字词（如 亡羊补牢），让四字词提前可见
  if #parts == 2 then
    local quad_hits = phrase_prefix_hits(parts, 4)
    for i = 1, math.min(#quad_hits, 3) do
      local w = quad_hits[i]
      if not found[w] then
        found[w] = {sf = WEIGHTS.sf_open - i * 1000, uf = learning.freq(w, env), cf = ngram.word_freq(last, w, env)}
      end
    end
  end
  for _, head in ipairs(head_candidates) do
    if not seen_head[head] then
      seen_head[head] = true
      local h_len = #head
      local first_ch = utf8_first_char(head)
      local bucket = head_words[first_ch] or {}
      for _, item in ipairs(bucket) do
        local w, sf = item[1], item[2]
        if #w > h_len and w:sub(1, h_len) == head then
          -- 只保留 N+1 字词（按分词段数锁定，候选区干净）
          local chs_n = 0
          for _ in w:gmatch("[\194-\244][\128-\191]*") do chs_n = chs_n + 1 end
          if chs_n == target_len then
            local uf = learning.freq(w, env)
            found[w] = {sf = sf, uf = uf, cf = ngram.word_freq(last, w, env)}
          end
        end
      end
      for w, uf in pairs(learning.all(env)) do
        if #w > h_len and w:sub(1, h_len) == head then
          local sf = words[w] or 0
          local chs_n = 0
          for _ in w:gmatch("[\194-\244][\128-\191]*") do chs_n = chs_n + 1 end
          if chs_n == target_len then
            found[w] = {sf = sf, uf = uf, cf = ngram.word_freq(last, w, env)}
          end
        end
      end
    end
  end


  local order = {}
  for w in pairs(found) do order[#order + 1] = w end

  if #order == 0 then
    -- 无匹配词组时：先用全量词库前缀预测 N+1 字词（如 亡羊' → 亡羊补牢），
    -- 再输出长度匹配的前缀词；最后才走部分回退（保护前段词 + 末段定字），绝不整串笔画兜底。
    local emitted_any = false
    local pred_hits = phrase_prefix_hits(parts, target_len)
    for i = 1, math.min(#pred_hits, 3) do
      emitted_any = true
      yield(make_candidate('phrase', seg.start, seg._end, pred_hits[i], raw_input))
    end
    if not emitted_any then
      for i = 1, math.min(#head_candidates, MAX_OUTPUT) do
        local h = head_candidates[i]
        local chs_n = 0
        for _ in h:gmatch("[\194-\244][\128-\191]*") do chs_n = chs_n + 1 end
        if chs_n == target_len then
          emitted_any = true
          yield(make_candidate('phrase', seg.start, seg._end, h, raw_input))
        end
      end
    end
    if not emitted_any then
      -- 无对应长度词时：保护前段已命中的词 + 末段以笔画重新定字（不用整串笔画兜底）
      fallback_partial(parts, raw_input, seg, env)
    end
    return
  end

  table.sort(order, function(a, b)
    local item_a, item_b = found[a], found[b]
    local au, bu = item_a.uf * WORD_UF_STEP + (item_a.cf or 0), item_b.uf * WORD_UF_STEP + (item_b.cf or 0)
    if au ~= bu then return au > bu end
    if item_a.sf ~= item_b.sf then return item_a.sf > item_b.sf end
    return a < b
  end)

  -- 只输出 N+1 字词候选（不输出单字/其他长度）
  for i = 1, math.min(#order, MAX_OUTPUT) do
    yield(make_candidate('phrase', seg.start, seg._end, order[i], raw_input))
  end
end

-- 上屏后的无按键智能连贯联想（字词上屏后，候选区自动跟出可连上的高频字词）
local demote_cache = {}
local demote_cache_time = 0
local DEMOTE_CACHE_TTL = 2  -- 秒
local function get_demote_set()
  local now = os.time()
  if now - demote_cache_time < DEMOTE_CACHE_TTL then
    return demote_cache
  end
  demote_cache = {}
  demote_cache_time = now
  local d = rime_api and rime_api.get_user_data_dir and rime_api:get_user_data_dir() or '.'
  local f = io.open(d .. '/demote.user.tsv', 'r')
  if f then
    for line in f:lines() do
      local w = line:match('^([^\t]+)\t%d+$') or line:match('^([^\t]+)$')
      if w and w ~= '' then
        demote_cache[w] = true
      end
    end
    f:close()
  end
  return demote_cache
end

local function build_predict_continuations(env)
  local last = learning.get_last_commit()
  if not last or last == '' then
    -- 还没有任何上屏记录时，给出可点的常用起句词，避免候选栏空白
    return {"你好", "我们", "可以", "这个", "什么", "现在", "今天", "没有"}
  end
  local l_len = #last

  -- prev2（倒数第二个上屏词）参与上下文加权（FastInput 多词历史思想）：cf = last 的上下文 + prev2 的上下文
  local prev2_ctx = learning.get_prev2_commit()
  local prev3_ctx = learning.get_prev3_commit()
  -- 键道「衔接词优先」：高频功能/衔接词在联想排序中给予固定加分，让候选更顺口
  local CONNECTOR_BONUS = WEIGHTS.connector
  local CONNECTORS = {
    ["的"]=true,["了"]=true,["是"]=true,["在"]=true,["有"]=true,["和"]=true,
    ["就"]=true,["都"]=true,["也"]=true,["不"]=true,["很"]=true,["要"]=true,
    ["会"]=true,["能"]=true,["去"]=true,["想"]=true,["说"]=true,["看"]=true,
    ["听"]=true,["来"]=true,["上"]=true,["下"]=true,["这"]=true,["那"]=true,
    ["我"]=true,["你"]=true,["他"]=true,["她"]=true,["它"]=true,["我们"]=true,
    ["你们"]=true,["他们"]=true,["吗"]=true,["呢"]=true,["吧"]=true,["啊"]=true,
    ["哦"]=true,["嗯"]=true,["好"]=true,["行"]=true,["对"]=true,["没"]=true,
    ["再"]=true,["又"]=true,["还"]=true,["却"]=true,["但"]=true,["所以"]=true,
    ["因为"]=true,["然后"]=true,["但是"]=true,["如果"]=true,
  }
  local function cf_of(w)
    local base = ngram.word_freq(last, w, env)
    if prev2_ctx and prev2_ctx ~= last then
      base = base + ngram.word_freq(prev2_ctx, w, env)
    end
    -- 衔接词固定加分（不改变语义排序，仅让常用功能词在联想中更靠前）
    if CONNECTORS[w] then base = base + CONNECTOR_BONUS end
    return base
  end

  local found = {}
  -- 任意词上屏后都有可接的通用后接词（数据驱动 unigram 兜底，替代固定虚词）。
  local generic = unigram_fallback
  for i, w in ipairs(generic) do
    found[w] = {sf = WEIGHTS.sf_generic - i * 100, uf = learning.freq(w, env), cf = cf_of(w)}
  end

  -- 0. 三连联想（最高优先）：连续上屏两个词后，用离线预训练 trigram 预测第三个词
  local prev2 = learning.get_prev2_commit()
  if prev2 and prev2 ~= last then
    local tri_list = next_words_tri[prev2 .. '\t' .. last]
    -- 离线模型未命中时，补充固定双前词短语联想（讯飞式句子级预测）
    if not tri_list then
      tri_list = phrase_assoc_tri[prev2 .. '\t' .. last]
    end
    if tri_list then
      for rank, w in ipairs(tri_list) do
        local uf = learning.freq(w, env)
        found[w] = {sf = WEIGHTS.sf_tri - (rank * 1000), uf = uf, cf = cf_of(w)}
      end
    end
  end

  -- 0.25 四连联想（最高优先）：连续上屏三个词后，用固定四词短语联想预测第四个词
  local prev3 = learning.get_prev3_commit()
  if prev3 and prev2 and prev3 ~= prev2 and prev2 ~= last then
    local quad_list = phrase_assoc_quad[prev3 .. '\t' .. prev2 .. '\t' .. last]
    if quad_list then
      for rank, w in ipairs(quad_list) do
        local uf = learning.freq(w, env)
        found[w] = {sf = WEIGHTS.sf_quad - (rank * 1000), uf = uf, cf = cf_of(w)}
      end
    end
  end

  -- 0.5 常用短语/句子联想（高频固定搭配，优先级高于通用 bigram、低于三连 trigram）
  local assoc_list = phrase_assoc[last]
  if assoc_list then
    for rank, w in ipairs(assoc_list) do
      local uf = learning.freq(w, env)
      found[w] = {sf = WEIGHTS.sf_assoc - (rank * 1000), uf = uf, cf = cf_of(w)}
    end
  end

  -- 1. 优先提取离线预训练二元文法 next_words_big[last]（百万级词库统计），其次手写 next_words[last]，输出最地道、最顺畅的后接词组，支持无限连击打字！
  local nxt_list = next_words_big[last] or next_words[last]
  if nxt_list then
    for rank, w in ipairs(nxt_list) do
      local uf = learning.freq(w, env)
      found[w] = {sf = WEIGHTS.sf_bigram - (rank * 1000), uf = uf, cf = cf_of(w)}
    end
  end

  -- 1.1 用户 bigram 直出（路线A/C）：用户历史中 last->X 的后接词直接作为候选。
  --     即使 X 不在静态联想表（如「句号 -> 下一句首词」）也能被预测；
  --     权重略高于静态 bigram（sf_bigram+50000），低于三连/短语联想。
  if last and last ~= '' and type(ngram.next_words) == 'function' then
    local ok_uw, user_list = pcall(function() return ngram.next_words(last, env) end)
    if ok_uw and type(user_list) == 'table' then
      for rank, item in ipairs(user_list) do
        local w = item.word
        if w and w ~= '' and not found[w] then
          found[w] = {
            sf = WEIGHTS.sf_bigram + 50000 - (rank - 1) * 1000,
            uf = learning.freq(w, env),
            cf = cf_of(w),
          }
        end
      end
    end
  end

  -- 2. 从 head_words 中截取后缀作为词内补全候选
  local first_ch = utf8_first_char(last)
  local bucket = head_words[first_ch] or {}
  for _, item in ipairs(bucket) do
    local w, sf = item[1], item[2]
    if #w > l_len and w:sub(1, l_len) == last then
      local suffix = w:sub(l_len + 1)
      local uf = learning.freq(suffix, env)
      local old = found[suffix]
      if not old or sf > old.sf or uf > (old.uf or 0) then
        found[suffix] = {sf = sf, uf = uf, cf = cf_of(suffix)}
      end
    end
  end

  -- 3. 在用户学习库中寻找
  for w, uf in pairs(learning.all(env)) do
    if #w > l_len and w:sub(1, l_len) == last then
      local suffix = w:sub(l_len + 1)
      local sf = words[suffix] or 0
      local old = found[suffix]
      if not old or uf > (old.uf or 0) then
        found[suffix] = {sf = sf, uf = uf, cf = cf_of(suffix)}
      end
    end
  end

  -- 4. 末尾字组词（降权）：上一个字的末尾字能组成的双字词，其第二字作为候选，支持连续组词联想
  local last_chs = utf8_chars(last)
  local tail_ch = last_chs[#last_chs]
  if tail_ch then
    local sorted_bucket = get_sorted_bucket(tail_ch)
    if sorted_bucket then
      for _, w in ipairs(sorted_bucket) do
        if #w == 6 then
          local second = w:sub(4, 6)
          local wf = words[w] or 0
          local old = found[second]
          if not old or (WEIGHTS.sf_tailword + wf) > (old.sf or 0) then
            found[second] = {sf = WEIGHTS.sf_tailword + wf, uf = learning.freq(second, env), cf = cf_of(second)}
          end
        end
      end
    end
  end

  local order = {}
  -- 动态循环抑制（路线C）：最近上屏过的 6 个词不再「一刀切排除」，
  -- 而是默认降权（sf 减半，仍可出现在候选列表靠后）；
  -- 若用户 bigram 中有「last -> 该词」的真实搭配记录，则不降权（允许真实重复搭配）。
  local recent = learning.get_recent_commits() or {}
  local recent_set = {}
  for i = math.max(1, #recent - 5), #recent do
    recent_set[recent[i]] = true
  end
  local strong_set = {}
  if last and last ~= '' and type(ngram.next_words) == 'function' then
    local ok_uw, user_list = pcall(function() return ngram.next_words(last, env) end)
    if ok_uw and type(user_list) == 'table' then
      for _, item in ipairs(user_list) do
        strong_set[item.word] = true
      end
    end
  end
  for s in pairs(found) do
    if recent_set[s] and not strong_set[s] then
      found[s].sf = math.floor((found[s].sf or 0) / 2)
    end
    order[#order + 1] = s
  end
  -- 个性化联想提权：用户上屏频次 uf 以大步长参与排序（1 次上屏 ≈ 1 次 ngram 上下文命中）
  local UF_STEP = WORD_UF_STEP
  table.sort(order, function(a, b)
    local item_a, item_b = found[a], found[b]
    local au, bu = item_a.uf * UF_STEP + (item_a.cf or 0), item_b.uf * UF_STEP + (item_b.cf or 0)
    if au ~= bu then return au > bu end
    if item_a.sf ~= item_b.sf then return item_a.sf > item_b.sf end
    return a < b
  end)

  -- 降权词排除：联想候选不输出 demote.user.tsv 中的词
  local demoted = get_demote_set()
  local out = {}
  for i = 1, #order do
    if #out >= 5 then break end
    local w = order[i]
    if not demoted[w] then
      out[#out + 1] = w
    end
  end
  return out
end

local function emit_predict_continuation(seg, env)
  local order = build_predict_continuations(env)
  for _, w in ipairs(order) do
    yield(Candidate('predict', seg.start, seg._end, w, ''))
  end
end

local function translator(input, seg, env)
  if not seg or seg.start == nil or seg._end == nil then return end
  if input and input:sub(1, 1) == 'V' then return end
  -- 纯字母输入（拼音反查）：交给 pinyin_reverse translator，本翻译器不输出笔画符号兜底
  if input and input:match("^[a-z]+$") then return end
  init(env)

  -- 每轮输入开始复位部分回退标志（本轮若走 fallback_partial 会重新置位，供过滤器放行）
  if env.engine then
    env.engine._bg5_fallback = false
  end

  -- 更新模糊笔画开关（切换时清空相关缓存）
  if env.engine and env.engine.context then
    local nf = env.engine.context:get_option("fuzzy_stroke") or false
    if nf ~= fuzzy_stroke_on then
      fuzzy_stroke_on = nf
      cache[env] = {}
      phrase_cache = {}
    end
  end

  -- 更新局部纠错开关（路线3，切换时清空相关缓存）
  if env.engine and env.engine.context then
    local nc = env.engine.context:get_option("correction_stroke")
    if nc == nil then nc = true end
    if nc ~= correction_stroke_on then
      correction_stroke_on = nc
      cache[env] = {}
      phrase_cache = {}
    end
  end

  -- 手机皮肤功能键兜底（元书 character 可能以文本输入到达，处理器收不到按键事件）
  -- ] = 降权：对当前高亮候选降频并移除
  if input:sub(-1, -1) == ']' then
    local ctx = env.engine and env.engine.context
    if ctx and ctx:has_menu() then
      local cand = ctx:get_selected_candidate()
      if cand and cand.text and cand.text ~= '' then
        learning.demote(cand.text, env)
        ctx:delete_current_selection()
      end
    end
    if ctx then ctx:delete_input(1) end
    return
  end
  -- [ = 下移：把高亮移到下一个候选
  if input:sub(-1, -1) == '[' then
    local ctx = env.engine and env.engine.context
    if ctx and ctx:has_menu() then
      local ok, idx = pcall(function() return ctx:get_selected_index() end)
      if ok and type(idx) == 'number' then
        ctx:select(idx + 1)
      end
    end
    if ctx then ctx:delete_input(1) end
    return
  end

  -- 顶部 preedit 显示笔画符号（如 323'53 -> 丿丨丿'乛丿），不显示阿拉伯数字
  if input and input ~= '' then
    local ctx = env.engine and env.engine.context
    if ctx and ctx.composition and not ctx.composition:empty() then
      local segobj = ctx.composition:back()
      if segobj then
        segobj.preedit = to_stroke_symbol(input)
      end
    end
  end

  -- 情况 0: 空输入状态（字/词刚刚上屏，等待用户打下一个字或点击联想）
  if not input or input == '' then
    emit_predict_continuation(seg, env)
    return
  end

  -- 情况 A: 刚按下分词符，末尾是 ' (例如 3121' 或 1324454' 或 31'32')
  -- 立即触发高频连缀联想（不限字数，字词皆通）
  if input:sub(-1, -1) == "'" then
    local prefix_expr = input:sub(1, -2)
    if prefix_expr ~= "" and not prefix_expr:find("''", 1, true) then
      emit_open_continuation(prefix_expr, input, seg, env)
      return
    end
  end

  -- 统计分词符数量
  local seg_count = 0
  for _ in input:gmatch("'") do seg_count = seg_count + 1 end

  if seg_count > 0 then
    -- 点 1 次分词：锁定 2 字词；点 2 次分词：锁定 3 字词；以此类推
    local target_len = seg_count + 1
    local parts = {}
    for p in input:gmatch("[^']+") do
      if p:match("^[12345?]+$") then
        parts[#parts + 1] = p
      end
    end

    if #parts == target_len then
      emit_phrase_with_parts(parts, target_len, input, seg, env)
      return
    end
    -- 若分段数量暂未完全对齐（例如刚按了分词键），优先输出第一段的匹配结果兜底
    if #parts >= 1 then
      emit_phrase_with_parts(parts, #parts, input, seg, env)
      return
    end
  else
    -- 无分词输入：只预测单字候选（不输出二字/三字/四字词，保持候选区干净）
    if input:match("^[12345?]+$") then
      emit_single(input, seg, env)
      return
    end
  end

  -- 全局终极保底：任何未预期的输入，候选显示笔画符号，绝不留白，绝不显示数字！
  local safe_sym = to_stroke_symbol(input)
  yield(make_candidate('single', seg.start, seg._end, safe_sym, input))
end

-- 返回表：librime-lua 的 lua_translator 调用表的 func 字段；
-- 同时导出联想候选生成函数，供 predict_space（空格连打）等模块复用。
-- 可选参数 last_override：外部传入的预测上下文（可含标点，如「。」），
-- 用于路线A（连打 fallback 的句号后预测）；不传则行为与旧版完全一致。
M.func = translator
M.get_predict_continuations = function(env, last_override)
  if last_override and last_override ~= '' then
    local saved = learning.get_last_commit()
    learning.set_last_commit(last_override)
    local out = build_predict_continuations(env)
    learning.set_last_commit(saved)
    return out
  end
  return build_predict_continuations(env)
end
return M
