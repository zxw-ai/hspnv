-- predict_next.lua v2: 上屏自动预测增强（候选输出状态机 + 混合候选）
-- =============================================================================
-- 在既有「上屏后联想」（segment_phrase 情况0：空输入时输出静态模型预测）基础上，
-- 本过滤器实现一个轻量「候选输出状态机」（借鉴讯飞 CandidateManager 状态模式）：
--
--   standby   （待机）：无输入且无最近上屏 → 不注入任何内容，透传现有预测
--   submitted （已提交）：上屏后 expire_seconds 秒内 → 用户 bigram 直出 + 颜文字混合
--   inputting （输入中）：有输入 → 仅做用户历史词的前缀融合（提前命中）
--
-- 三个增量能力：
--   1. 用户 bigram 直出（submitted 态）：
--      空输入（刚上屏）时，把 ngram 用户历史中 last->X 的后接词直接排到预测最前。
--      即使 X 不在静态联想表（next_words_big/phrase_assoc）里，也能被预测。
--
--   2. 输入中融合（inputting 态）：
--      用户打下一个字时，用户历史中能匹配当前笔画前缀的后接词提前。
--      例如历史学过 "上屏->补"，打 "补" 的前缀码 45 时，"补" 直接出现在候选最前。
--
--   3. 混合候选（submitted 态，路线 G）：
--      预测段末尾追加常用颜文字/表情（可开关），让候选区在句子停顿处更生动。
--
--   4. 可选超时隐藏（submitted -> standby）：
--      空输入预测在 commit 后 N 秒不再显示（候选区留白），避免预测词长期占位。
--
-- 挂载（stroke_hspnv_learning.schema.yaml 的 filters 链【末尾】追加一行）：
--   - lua_filter@*predict_next
--
-- 配置段（schema 的 predict_next: 段）：
--   predict_next:
--     enable: true            # false 时本过滤器完全透传
--     expire_seconds: 0        # 0=不超时；>0 表示空输入预测在 N 秒后不再显示
--     inputting_fusion: true   # 输入中：用户历史词前缀融合
--     mix_kaomoji: true        # 空输入预测末尾追加颜文字
--     mix_punct: true          # 空输入预测末尾追加常用标点快捷候选（，。？！……）
--
-- 依赖：learning / ngram / stroke / words（require 方式与 segment_phrase 一致）
-- =============================================================================

local learning = nil
local ngram = nil
local stroke = nil
local words = nil
local deps_loaded = false
local EXPIRE_SECONDS = 0
local ENABLED = true
local INPUTTING_FUSION = true
local MIX_KAOMOJI = true
local MIX_PUNCT = true

-- 常用标点快捷候选（② 符号快捷栏的 Rime 侧入口；点击直接上屏，供句子连打收尾）
local PUNCT_LIST = {
  "，", "。", "？", "！", "……", "、", "：", "；",
}

-- 常用颜文字（纯文本、无空格歧义；点击直接上屏，不参与学习）
local KAOMOJI_LIST = {
  "(•́ω•̀)",
  "(●—●)",
  "(＾▽＾)",
  "(*≧ω≦)",
  "(｡•̀ᴗ-)✧",
  "٩(◕‿◕)۶",
  "_(:з」∠)_",
  "¯\\_(ツ)_/¯",
}

-- ---- 配置 ----
local function load_config(env)
  if not env or not env.engine or not env.engine.schema or not env.engine.schema.config then return end
  local cfg = env.engine.schema.config
  local v = cfg:get_bool('predict_next/enable')
  if v ~= nil then ENABLED = v end
  v = cfg:get_int('predict_next/expire_seconds')
  if v and v > 0 then EXPIRE_SECONDS = v end
  v = cfg:get_bool('predict_next/inputting_fusion')
  if v ~= nil then INPUTTING_FUSION = v end
  v = cfg:get_bool('predict_next/mix_kaomoji')
  if v ~= nil then MIX_KAOMOJI = v end
  v = cfg:get_bool('predict_next/mix_punct')
  if v ~= nil then MIX_PUNCT = v end
end

-- ---- 依赖加载（任何一步失败都不影响主流程，直接透传） ----
local function load_deps()
  if deps_loaded then return true end
  local ok
  ok, learning = pcall(require, 'learning')
  if not ok then return false end
  ok, ngram = pcall(require, 'ngram')
  if not ok then return false end
  ok, stroke = pcall(require, 'stroke')
  if not ok then return false end
  ok, words = pcall(require, 'words')
  if not ok then return false end
  deps_loaded = true
  return true
end

-- ---- 工具 ----
local function get_cand_text(cand)
  if cand and cand.text and cand.text ~= '' then return cand.text end
  if cand and type(cand.get_text) == 'function' then
    local ok, text = pcall(function() return cand:get_text() end)
    if ok and text and text ~= '' then return text end
  end
  return nil
end

local function get_seg(env)
  local ctx = env.engine and env.engine.context
  if ctx and ctx.composition and not ctx.composition:empty() then
    return ctx.composition:back()
  end
  return nil
end

-- 词 -> 整词笔画码（任一字符不在笔画表则返回 nil）
local function stroke_of(w)
  local code = {}
  for ch in w:gmatch("[\1-\127\194-\244][\128-\191]*") do
    local c = stroke[ch]
    if not c then return nil end
    code[#code + 1] = c
  end
  if #code == 0 then return nil end
  return table.concat(code)
end

-- ---- 降权词缓存（与 demote_filter 同一数据源，防止降权词被本过滤器重新插入） ----
local demote_cache = nil
local demote_cache_time = 0
local DEMOTE_CACHE_TTL = 30
local function is_demoted(w)
  local now = os.time()
  if not demote_cache or now - demote_cache_time > DEMOTE_CACHE_TTL then
    demote_cache = {}
    demote_cache_time = now
    local d = rime_api and rime_api.get_user_data_dir and rime_api:get_user_data_dir() or '.'
    local f = io.open(d .. '/demote.user.tsv', 'r')
    if f then
      for line in f:lines() do
        local w2 = line:match('^([^\t]+)\t%d+$') or line:match('^([^\t]+)$')
        if w2 and w2 ~= '' then demote_cache[w2] = true end
      end
      f:close()
    end
  end
  return demote_cache[w] == true
end

-- 该词是否值得作为预测输出：
-- 1. 词库中存在（words 有权重 或 整词都有笔画码）
-- 2. 不在最近上屏词中（避免刚上屏的词又作为预测出现）
-- 3. 未被手动降权
local function should_show(w, env)
  if not w or w == '' then return false end
  local chars = 0
  for _ in w:gmatch("[\1-\127\194-\244][\128-\191]*") do chars = chars + 1 end
  if chars == 0 then return false end
  -- 词库存在性：words 有权重，或每个字都能查笔画码（用户历史词必然可输）
  local wf = words[w] or 0
  if wf <= 0 then
    if not stroke_of(w) then return false end
  end
  if is_demoted(w) then return false end
  local recent = learning.get_recent_commits() or {}
  for i = #recent, math.max(1, #recent - 1), -1 do
    if recent[i] == w then return false end
  end
  return true
end

-- 用户 bigram 后接词列表（ngram.next_words 返回 {word=, cnt=} 数组，已按次数降序）
local function user_next_words(last, env)
  if not last or last == '' then return {} end
  if type(ngram.next_words) ~= 'function' then return {} end
  local ok, list = pcall(function() return ngram.next_words(last, env) end)
  if not ok or type(list) ~= 'table' then return {} end
  return list
end

-- ---- 惰性挂载 commit 时间戳（供超时隐藏使用） ----
local function lazy_attach(env)
  if env._bg5_predict_next_attached then return end
  local ctx = env.engine and env.engine.context
  if ctx and ctx.commit_notifier then
    local function on_commit()
      if env.engine then
        env.engine._bg5_predict_last_commit_time = os.time()
      end
    end
    local ok = pcall(function() ctx.commit_notifier:connect(on_commit) end)
    if not ok then return end
  end
  env._bg5_predict_next_attached = true
end

-- ---- 主过滤器 ----
local function filter(input, env)
  if not load_deps() then
    for cand in input:iter() do yield(cand) end
    return
  end
  load_config(env)
  if not ENABLED then
    for cand in input:iter() do yield(cand) end
    return
  end

  local ctx = env.engine and env.engine.context
  local inpt = (ctx and ctx.input) or ''
  lazy_attach(env)

  -- 收集现有候选（先全部取出，再按需重排输出）
  local existing = {}
  for cand in input:iter() do
    existing[#existing + 1] = cand
  end

  -- 超时隐藏：空输入预测只在 commit 后 expire_seconds 内显示
  if inpt == '' and EXPIRE_SECONDS > 0 then
    local t = (env.engine and env.engine._bg5_predict_last_commit_time) or 0
    if os.time() - t > EXPIRE_SECONDS then
      return  -- 候选区留白
    end
  end

  local seg = get_seg(env)
  local s, e = 0, 0
  if seg then s, e = seg.start, seg._end end

  -- 预测上下文：优先用 ngram 的「含标点」最近上屏（支持 句号->下一句首词），
  -- 无标点记录时退回 learning 的纯中文最近上屏。
  local last = ''
  if type(ngram.get_last_text) == 'function' then
    local ok_l, v = pcall(function() return ngram.get_last_text() end)
    if ok_l and v then last = v end
  end
  if last == '' then
    last = learning.get_last_commit() or ''
  end
  local seen = {}

  -- 阶段 1：用户 bigram 个性化候选（排最前）
  if last and last ~= '' then
    local user_list = user_next_words(last, env)
    if inpt == '' then
      -- submitted 态：全量直出（最个性化的历史搭配优先）
      for _, item in ipairs(user_list) do
        local w = item.word
        if w and not seen[w] and should_show(w, env) then
          seen[w] = true
          yield(Candidate('predict_next', s, e, w, ''))
        end
      end
    elseif INPUTTING_FUSION then
      -- inputting 态：只输出能匹配当前笔画前缀的用户历史后接词
      for _, item in ipairs(user_list) do
        local w = item.word
        if w and not seen[w] and should_show(w, env) then
          local code = stroke_of(w)
          if code and code:sub(1, #inpt) == inpt then
            seen[w] = true
            yield(Candidate('predict_next', s, e, w, ''))
          end
        end
      end
    end
  end

  -- 阶段 2：现有候选（用户词已输出的则去重跳过）
  for _, cand in ipairs(existing) do
    local text = get_cand_text(cand)
    if not text or not seen[text] then
      yield(cand)
    end
  end

  -- 阶段 3（submitted 态混合候选，②符号快捷栏 + 路线 G 颜文字）：预测段末尾追加常用标点与颜文字
  if inpt == '' and #existing > 0 then
    if MIX_PUNCT then
      for _, p in ipairs(PUNCT_LIST) do
        if not seen[p] then
          seen[p] = true
          yield(Candidate('predict_next', s, e, p, ''))
        end
      end
    end
    if MIX_KAOMOJI then
      for _, k in ipairs(KAOMOJI_LIST) do
        if not seen[k] then
          seen[k] = true
          yield(Candidate('predict_next', s, e, k, ''))
        end
      end
    end
  end
end

-- 兼容 librime-lua：lua_filter 模块返回表，librime 调用表的 func 字段
return { func = filter }