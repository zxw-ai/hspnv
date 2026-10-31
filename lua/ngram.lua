-- BG5 n-gram v2：轻量级上下文联想模块（含标点 bigram）
-- 为 segment_phrase 提供“上下文分”（cf），让笔画输入在连续输入时候选更精准：
--   1. 词级 bigram：前一个上屏词 -> 下一个词（用于词组候选排序）
--   2. 字级 bigram：前一个上屏词 -> 下一个词的首字（用于单字候选排序）
--   3. 标点 bigram（v2 新增）：标点也作为合法上下文单元——
--      「词 -> 标点」与「标点 -> 下一句首词」都会被学习，
--      配合标点顶字实现「句子 -> 标点 -> 下一句预测」的连贯闭环。
-- 数据保存在用户目录 bg5-ngram.user.tsv，配置在 schema 的 ngram: 段。

local M = {}
local loaded = false
local data = {}         -- 前词..'\t'..后词 -> 次数
local char_data = {}    -- 前词..'\t'..首字 -> 次数
local tri_data = {}     -- 前二词..'\t'..前词..'\t'..后词 -> 次数（用户三元组）
-- 每条搭配的最后使用时间（用于按龄衰减：查询时打折，不改存储）
local data_ts, char_ts, tri_ts = {}, {}, {}
-- 个人语料种子（只读）：与用户实时学习分开存放，避免被写回用户文件
local seed_data, seed_char, seed_tri = {}, {}, {}
local by_prev = {}      -- 前词 -> {后词=次数} 索引（next_words 免全表遍历，长期使用性能优化）
local by_prev_total = {} -- 前词 -> 总次数（条件概率 P(w|prev) 的分母）
local by_prev2 = {}     -- 前二词..'\t'..前词 -> {后词=次数}（next_words3 索引）
local path = nil
local prev_commit = nil
local prev2_commit = nil
local last_commit = nil
local tri_count = 0
local save_counter = 0
local SAVE_INTERVAL = 8

-- 配置默认值（可由 schema 的 ngram: 段覆盖）
local ENABLED = true
local WORD_STEP = 200000
local WORD_CAP = 3
local CHAR_STEP = 100000
local CHAR_CAP = 2
local TRI_ENABLE = true      -- 用户三元组（前两个词 -> 下一个词）
local TRI_CAP = 2            -- 三元组次数上限（防止单条霸榜）
local TRI_MAX_ENTRIES = 20000 -- 三元组条目上限（超出时丢弃只出现 1 次的旧搭配，控制内存与写盘）
local HALF_LIFE_DAYS = 30    -- 搭配半衰期：30 天不用，权重减半（只影响查询打分，不改存储）

local function user_dir()
  if rime_api and rime_api.get_user_data_dir then
    local d = rime_api:get_user_data_dir()
    if d and d ~= '' then return d end
  end
  return '.'
end

local function utf8_chars(s)
  local t = {}
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    t[#t + 1] = ch
  end
  return t
end

local function chinese_only(s)
  if not s or s == '' then return false end
  local chars = utf8_chars(s)
  if #chars == 0 then return false end
  for _, ch in ipairs(chars) do
    if #ch < 3 or ch:byte() < 0x80 then return false end
  end
  return true
end

-- 标点集合：参与 bigram 的标点（与键盘标点键输出一致）
local PUNCT_SET = {}
for ch in ("，。？！、；：,.?!;:"):gmatch("[\1-\127\194-\244][\128-\191]*") do
  PUNCT_SET[ch] = true
end

local function is_punct(s)
  if not s or s == '' then return false end
  local chars = utf8_chars(s)
  return #chars == 1 and PUNCT_SET[chars[1]] == true
end

-- 合法的 n-gram 单元：纯中文 或 单个标点
local function is_valid_unit(s)
  if not s or s == '' then return false end
  if is_punct(s) then return true end
  return chinese_only(s)
end

-- 按「最后使用时间」打折：0.5 ^ (龄 / 半衰期)
local function decay_factor(ts)
  if not ts or ts <= 0 then return 1 end
  local age = os.time() - ts
  if age <= 0 then return 1 end
  return 0.5 ^ (age / (HALF_LIFE_DAYS * 86400))
end

local function load_config(env)
  if not env or not env.engine or not env.engine.schema or not env.engine.schema.config then return end
  local cfg = env.engine.schema.config
  local v
  v = cfg:get_bool("ngram/enable")
  if v ~= nil then ENABLED = v end
  v = cfg:get_int("ngram/word_weight")
  if v then WORD_STEP = v end
  v = cfg:get_int("ngram/word_cap")
  if v then WORD_CAP = v end
  v = cfg:get_int("ngram/char_weight")
  if v then CHAR_STEP = v end
  v = cfg:get_int("ngram/char_cap")
  if v then CHAR_CAP = v end
  v = cfg:get_bool("ngram/tri_enable")
  if v ~= nil then TRI_ENABLE = v end
  v = cfg:get_int("ngram/tri_cap")
  if v then TRI_CAP = v end
  v = cfg:get_int("ngram/half_life_days")
  if v and v > 0 then HALF_LIFE_DAYS = v end
end

local function rebuild_tri_index()
  by_prev2 = {}
  local merged_tri = {}
  for k, n in pairs(seed_tri) do merged_tri[k] = (merged_tri[k] or 0) + n end
  for k, n in pairs(tri_data) do merged_tri[k] = (merged_tri[k] or 0) + n end
  for k, n in pairs(merged_tri) do
    local a, b, c = k:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
    if a and b and c then
      local k2 = a .. '\t' .. b
      local bp2 = by_prev2[k2]
      if not bp2 then bp2 = {}; by_prev2[k2] = bp2 end
      bp2[c] = n
    end
  end
end

-- 个人语料种子（tools/gen_personal_ngram.lua 生成）：
-- 低权重并入用户上下文模型，作为冷启动时「像自己说话」的先验。
-- 找不到文件时静默跳过（不影响正常使用）。
local function load_personal_seed(d)
  local paths = {}
  if rime_api and rime_api.get_shared_data_dir then
    local ok, sd = pcall(function() return rime_api:get_shared_data_dir() end)
    if ok and sd and sd ~= '' then paths[#paths + 1] = sd .. '/personal_ngram.tsv' end
  end
  paths[#paths + 1] = d .. '/personal_ngram.tsv'
  for _, p in ipairs(paths) do
    local f = io.open(p, 'r')
    if f then
      for line in f:lines() do
        local kind, a, b, n = line:match('^([WC])\t([^\t]+)\t([^\t]+)\t(%d+)$')
        if kind == 'W' then
          seed_data[a .. '\t' .. b] = tonumber(n)
        elseif kind == 'C' then
          seed_char[a .. '\t' .. b] = tonumber(n)
        else
          local t1, t2, t3, t4 = line:match('^T\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)$')
          if t1 then seed_tri[t1 .. '\t' .. t2 .. '\t' .. t3] = tonumber(t4) end
        end
      end
      f:close()
      return true
    end
  end
  return false
end

local function load(env)
  if loaded then return end
  loaded = true
  load_config(env)
  local d = user_dir()
  path = d .. '/bg5-ngram.user.tsv'
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      -- 新格式带时间戳：W\t前词\t后词\t次数\t时间；旧格式只有 4 列
      local kind, a, b, n, ts = line:match('^([WC])\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)$')
      if not kind then
        kind, a, b, n = line:match('^([WC])\t([^\t]+)\t([^\t]+)\t(%d+)$')
      end
      ts = tonumber(ts) or 0
      if kind == 'W' then
        local k = a .. '\t' .. b
        data[k] = tonumber(n)
        if ts > 0 then data_ts[k] = ts end
      elseif kind == 'C' then
        local k = a .. '\t' .. b
        char_data[k] = tonumber(n)
        if ts > 0 then char_ts[k] = ts end
      else
        local c1, c2, c3, c4, c5 = line:match('^T\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)$')
        if not c1 then c1, c2, c3, c4 = line:match('^T\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)$') end
        if c1 then
          local k = c1 .. '\t' .. c2 .. '\t' .. c3
          tri_data[k] = tonumber(c4)
          if tonumber(c5) then tri_ts[k] = tonumber(c5) end
        end
      end
    end
    f:close()
  end
  -- 个人语料种子（可选）
  load_personal_seed(d)
  -- 重建前词索引（next_words 免全表遍历；用户数据 + 个人语料种子合并）
  by_prev = {}
  by_prev_total = {}
  local merged = {}
  for k, n in pairs(seed_data) do merged[k] = (merged[k] or 0) + n end
  for k, n in pairs(data) do merged[k] = (merged[k] or 0) + n end
  for k, n in pairs(merged) do
    local a, b = k:match('^([^\t]+)\t([^\t]+)$')
    if a and b then
      local bp = by_prev[a]
      if not bp then bp = {}; by_prev[a] = bp end
      bp[b] = n
      by_prev_total[a] = (by_prev_total[a] or 0) + n
    end
  end
  -- 重建三元组索引
  rebuild_tri_index()
  tri_count = 0
  for _ in pairs(tri_data) do tri_count = tri_count + 1 end
end

local function safe_save(p, t1, t2, t3)
  local tmp = p .. '.tmp.' .. tostring(math.random(100000, 999999))
  local f = nil
  local ok = pcall(function()
    f = assert(io.open(tmp, 'w'))
    local now = os.time()
    for k, n in pairs(t1) do
      local a, b = k:match('^([^\t]+)\t([^\t]+)$')
      if a and b then f:write('W\t', a, '\t', b, '\t', tostring(n), '\t', tostring(data_ts[k] or now), '\n') end
    end
    for k, n in pairs(t2) do
      local a, b = k:match('^([^\t]+)\t([^\t]+)$')
      if a and b then f:write('C\t', a, '\t', b, '\t', tostring(n), '\t', tostring(char_ts[k] or now), '\n') end
    end
    for k, n in pairs(t3) do
      local a, b, c = k:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
      if a and b and c then f:write('T\t', a, '\t', b, '\t', c, '\t', tostring(n), '\t', tostring(tri_ts[k] or now), '\n') end
    end
    f:close()
    f = nil
    os.rename(tmp, p)
  end)
  if f then pcall(function() f:close() end) end
  if not ok then pcall(os.remove, tmp) end
end

local function save()
  if path then safe_save(path, data, char_data, tri_data) end
end

function M.word_freq(prev, w, env)
  load(env)
  if not ENABLED or not prev or prev == '' or not w or w == '' then return 0 end
  local k = prev .. '\t' .. w
  local n = data[k] or seed_data[k]
  if n then
    local f = 1
    local ts = data_ts[k]
    if ts then f = decay_factor(ts) end
    return math.min(n, WORD_CAP) * WORD_STEP * f
  end
  return 0
end

function M.char_freq(prev, ch, env)
  load(env)
  if not ENABLED or not prev or prev == '' or not ch or ch == '' then return 0 end
  local k = prev .. '\t' .. ch
  local n = char_data[k] or seed_char[k]
  if n then
    local f = 1
    local ts = char_ts[k]
    if ts then f = decay_factor(ts) end
    return math.min(n, CHAR_CAP) * CHAR_STEP * f
  end
  return 0
end

-- 最近一次上屏文本（含标点；若无标点则为纯中文）
-- 供 predict_next 在句号后预测下一句开头词。
function M.get_last_commit()
  return last_commit
end
M.get_last_text = M.get_last_commit

-- 前前一个上屏词（用户三元组的上下文）
function M.get_prev2()
  return prev2_commit
end

-- 获取某个前词在用户历史中的所有后接词（按次数降序）
-- 供 predict_next（上屏自动预测增强）把用户个性化搭配直接作为候选输出。
function M.next_words(prev, env)
  load(env)
  if not ENABLED or not prev or prev == '' then return {} end
  local bp = by_prev[prev]
  if not bp then return {} end
  local out = {}
  local now = os.time()
  for w, n in pairs(bp) do
    local ts = data_ts[prev .. '\t' .. w]
    local f = ts and decay_factor(ts) or 1
    out[#out + 1] = { word = w, cnt = n * f }
  end
  -- 同次数时按词排序：Lua 的 pairs 顺序不稳定，不加 tie-break 会让同一份数据的
  -- 联想顺序在两次启动间抖动（排序名次还会影响 sf 递减）。
  table.sort(out, function(a, b)
    if a.cnt ~= b.cnt then return a.cnt > b.cnt end
    return a.word < b.word
  end)
  return out
end

-- 条件概率 P(w | prev)（用户 bigram）；无记录返回 nil
function M.pair_prob(prev, w, env)
  load(env)
  if not ENABLED or not prev or prev == '' or not w or w == '' then return nil end
  local bp = by_prev[prev]
  if not bp then return nil end
  local n = bp[w]
  local total = by_prev_total[prev]
  if not n or not total or total <= 0 then return nil end
  return n / total
end

-- 归一化条件概率：P(w|prev) × 后继词种类数（「比均匀分布好多少」，无信息时为 1）
-- 返回 (norm, follower_count)
function M.pair_prob_norm(prev, w, env)
  load(env)
  if not ENABLED or not prev or prev == '' or not w or w == '' then return nil end
  local bp = by_prev[prev]
  if not bp then return nil end
  local n = bp[w]
  local total = by_prev_total[prev]
  if not n or not total or total <= 0 then return nil end
  local k = 0
  for _ in pairs(bp) do k = k + 1 end
  return (n / total) * k, k
end

-- 获取「前两个词 -> 下一个词」的用户三元组（按次数降序）
function M.next_words3(p2, p1, env)
  load(env)
  if not ENABLED or not TRI_ENABLE then return {} end
  if not p2 or p2 == '' or not p1 or p1 == '' then return {} end
  if is_punct(p2) or is_punct(p1) then return {} end
  local bp2 = by_prev2[p2 .. '\t' .. p1]
  if not bp2 then return {} end
  local out = {}
  for w, n in pairs(bp2) do
    local ts = tri_ts[p2 .. '\t' .. p1 .. '\t' .. w]
    local f = ts and decay_factor(ts) or 1
    out[#out + 1] = { word = w, cnt = n * f }
  end
  table.sort(out, function(a, b)
    if a.cnt ~= b.cnt then return a.cnt > b.cnt end
    return a.word < b.word
  end)
  return out
end

-- 三元组次数上限（供上层换算分数时使用）
function M.tri_cap() return TRI_CAP end

local function learn_pair(prev, cur, p2)
  if not prev or prev == '' or not cur or cur == '' then return end
  -- 至少一方是中文词/字；不允许「标点 -> 标点」
  if not is_valid_unit(prev) or not is_valid_unit(cur) then return end
  if is_punct(prev) and is_punct(cur) then return end
  local now = os.time()
  local wk = prev .. '\t' .. cur
  data[wk] = (data[wk] or 0) + 1
  data_ts[wk] = now
  -- 同步更新前词索引
  local bp = by_prev[prev]
  if not bp then bp = {}; by_prev[prev] = bp end
  bp[cur] = (bp[cur] or 0) + 1
  by_prev_total[prev] = (by_prev_total[prev] or 0) + 1
  -- 用户三元组：前两个词 -> 当前词（标点不参与，避免跨句噪声）
  if TRI_ENABLE and p2 and p2 ~= '' and p2 ~= prev and not is_punct(p2) and not is_punct(cur) then
    local tk = p2 .. '\t' .. prev .. '\t' .. cur
    if tri_data[tk] == nil then tri_count = tri_count + 1 end
    tri_data[tk] = (tri_data[tk] or 0) + 1
    tri_ts[tk] = now
    if tri_count > TRI_MAX_ENTRIES then
      -- 超过上限：丢弃只出现 1 次的旧搭配，控制内存与写盘
      local keep = {}
      for k, n in pairs(tri_data) do
        if n > 1 then keep[k] = n end
      end
      tri_data = keep
      tri_count = 0
      for _ in pairs(tri_data) do tri_count = tri_count + 1 end
      rebuild_tri_index()
    end
    local k2 = p2 .. '\t' .. prev
    local bp2 = by_prev2[k2]
    if not bp2 then bp2 = {}; by_prev2[k2] = bp2 end
    bp2[cur] = (bp2[cur] or 0) + 1
  end
  -- 记录 前词 -> 当前词首字（标点也记录其本身作为“首字”，供 char_freq 查询）
  local chars = utf8_chars(cur)
  local first = chars[1]
  if first then
    local ck = prev .. '\t' .. first
    char_data[ck] = (char_data[ck] or 0) + 1
    char_ts[ck] = now
  end
end

-- 仅更新上下文（不学习、不写盘）：供 predict_space 连打上屏「通用兜底词」时使用，
-- 避免兜底词（的/了/吧/啊/是）污染用户 bigram 导致连打反复上屏同一词。
function M.touch_context(text, env)
  load(env)
  if not text or text == '' then return end
  if not is_valid_unit(text) then return end
  prev2_commit = prev_commit
  prev_commit = text
  last_commit = text
end

-- 手动提交通知（供 predict_space 在 commit_text 后调用）
-- commit_text 不触发 commit_notifier，若不手动更新，ngram 上下文不会推进，
-- 「句号->下一句」链路在纯 fallback 连打时会断。
function M.notify_commit(text, env)
  load(env)
  if not text or text == '' then return end
  if not is_valid_unit(text) then return end
  if prev_commit and prev_commit ~= text then
    learn_pair(prev_commit, text, prev2_commit)
  end
  prev2_commit = prev_commit
  prev_commit = text
  last_commit = text
  save_counter = save_counter + 1
  if save_counter >= SAVE_INTERVAL then
    save_counter = 0
    save()
  end
end

function M.attach(env)
  if not env or not env.engine or not env.engine.context then return false end
  load(env)
  if not ENABLED then return true end
  local c = env.engine.context
  if not c.commit_notifier then return false end
  if env._bg5_ngram_connected then return true end
  local function on_commit(ctx)
    local text = ctx:get_commit_text() or ''
    -- 纯中文词或标点都参与上下文学习
    if text ~= '' and is_valid_unit(text) then
      if prev_commit and prev_commit ~= text then
        learn_pair(prev_commit, text, prev2_commit)
      end
      prev2_commit = prev_commit
      prev_commit = text
      last_commit = text
      save_counter = save_counter + 1
      if save_counter >= SAVE_INTERVAL then
        save_counter = 0
        save()
      end
    end
  end
  c.commit_notifier:connect(on_commit)
  env._bg5_ngram_connected = true
  return true
end

return M