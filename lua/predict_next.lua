-- predict_next.lua v3: 上屏自动预测增强（候选输出状态机 + 混合候选）
-- =============================================================================
-- 在既有「上屏后联想」（segment_phrase 情况0：空输入时输出静态模型预测）基础上，
-- 本过滤器实现一个轻量「候选输出状态机」（借鉴讯飞 CandidateManager 状态模式）：
--
--   standby   （待机）：无输入且无最近上屏 → 不注入任何内容，透传现有预测
--   submitted （已提交）：上屏后 expire_seconds 秒内 → 用户 bigram 直出 + 混合候选
--   inputting （输入中）：有输入 → 仅做用户历史词的前缀融合（提前命中）
--
-- 增量能力：
--   1. 用户 bigram 直出（submitted 态）：
--      空输入（刚上屏）时，把 ngram 用户历史中 last->X 的后接词直接排到预测最前。
--      即使 X 不在静态联想表（next_words_big/phrase_assoc）里，也能被预测。
--   2. 输入中融合（inputting 态）：用户打下一个字时，用户历史中能匹配当前笔画前缀的后接词提前。
--   3. 混合候选（submitted 态，首页预算制）：用剩余名额追加
--      - 词→emoji（与刚上屏的词强相关）
--      - 常用标点快捷候选（② 符号快捷栏）
--      - 常用语快捷候选（对标讯飞常用语面板，如 好的/收到/谢谢/没问题）
--      - 常用颜文字（路线 G，让停顿处更生动）
--      预算 = mix_page_size - min(真实候选数, mix_real_keep)：真实联想优先占位，
--      快捷项只补空位（旧版无脑全追加，空输入时候选区里 32 个快捷项挤掉联想）。
--   4. 可选超时隐藏（submitted -> standby）：空输入预测在 commit 后 N 秒不再显示。
--   5. 过滤器位置：必须排在 charset_filter / simplifier / uniquifier **之前**，
--      否则注入的候选会绕过字符集（小字集）、简繁转换与去重。
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
--     mix_quick: true          # 空输入预测末尾追加常用语快捷候选（好的/收到/谢谢…）
--     mix_emoji: true          # 空输入预测末尾追加「词→emoji」联想（开心→😊，数据 lua/data/emoji_assoc.txt）
--     inputting_min_len: 3     # 输入中融合最少输入位数（保护首两笔短码选字）
--     mix_page_size: 9         # 首页候选预算
--     mix_real_keep: 6         # 首页最多留给真实联想的个数
--     mix_punct_max / mix_quick_max / mix_emoji_max / mix_kaomoji_max  # 各类快捷项上限
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

-- 部首/笔画符号集合（与 segment_phrase 一致）：预测候选不输出偏旁部首和非「一」的单笔符号。
-- 「一」是常用汉字，保留。
local NON_WORD_CHARS = {}
for ch in ("丨丿丶乙亅乀乁乚乛"):gmatch("[\1-\127\194-\244][\128-\191]*") do
  NON_WORD_CHARS[ch] = true
end
for ch in ("氵亻艹扌辶讠纟饣忄阝宀疒礻衤钅彳犭夂攵冖冂勹匚廴彡卩厶巛灬爫户戈攴疋癶缶聿艮豸"):gmatch("[\1-\127\194-\244][\128-\191]*") do
  NON_WORD_CHARS[ch] = true
end
local MIX_PUNCT = true
local MIX_QUICK = true
local MIX_EMOJI = true   -- 上屏后追加「词→emoji」联想候选（对标讯飞 RLEmojiAssociateDict）
-- 混合候选预算（关键：混合项不能挤占真实联想）
--   首页预算 = mix_page_size（与 menu/page_size 一致），其中最多保留 mix_real_keep 个真实联想，
--   剩余名额才给 标点/emoji/常用语/颜文字，且每类有独立上限。
--   旧版是「无条件全部追加」，空输入时真实联想 5 个 + 混合 32 个 → 要翻 4 页才能看到下一批联想。
local MIX_PAGE_SIZE = 9
local MIX_REAL_KEEP = 6
local MIX_PUNCT_MAX = 1
local MIX_QUICK_MAX = 2
local MIX_EMOJI_MAX = 1
local MIX_KAOMOJI_MAX = 1
local INPUTTING_MIN_LEN = 3   -- 输入中融合：至少输入 N 位才启用（保护首两笔短码选字）
local MAX_USER_NEXT = 4       -- 空输入时用户 bigram 直出上限（防止个人搭配把候选区刷满）

-- 常用标点快捷候选（② 符号快捷栏的 Rime 侧入口；点击直接上屏，供句子连打收尾）
local PUNCT_LIST = {
  "。", "，", "？", "！", "……", "、", "：", "；",
}

-- 常用语快捷候选（对标讯飞「常用语面板」：上屏停顿处直接点选，少打整词笔画）
-- 全部为高频口语短词，纯中文可输；点击直接上屏，不参与学习。
local QUICK_PHRASES = {
  "好的", "收到", "谢谢", "没问题", "哈哈哈", "嗯嗯", "知道了", "可以",
  "好的呢", "收到啦", "辛苦啦", "马上到", "在忙", "稍后说", "晚安", "早安",
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

-- 词→emoji 联想表（对标讯飞 RLEmojiAssociateDict，数据来自 lua/data/emoji_assoc.txt）
-- 上屏「开心」→ 候选区追加 😊；「哈哈」→ 😄 等。
local EMOJI_ASSOC = nil
local EMOJI_ASSOC_LOADED = false
local function load_emoji_assoc()
  if EMOJI_ASSOC_LOADED then return EMOJI_ASSOC end
  EMOJI_ASSOC_LOADED = true
  local map = {}
  local paths = {}
  if rime_api then
    local ud = rime_api.get_user_data_dir and rime_api:get_user_data_dir()
    if ud and ud ~= '' then paths[#paths + 1] = ud .. '/lua/data/emoji_assoc.txt' end
    local sd = rime_api.get_shared_data_dir and rime_api:get_shared_data_dir()
    if sd and sd ~= '' then paths[#paths + 1] = sd .. '/lua/data/emoji_assoc.txt' end
  end
  paths[#paths + 1] = 'lua/data/emoji_assoc.txt'
  local f
  for _, p in ipairs(paths) do
    local ok, fp = pcall(io.open, p, 'r')
    if ok and fp then f = fp break end
  end
  if f then
    for raw_line in f:lines() do
      local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= '' and not line:match('^#') then
        local word, emoji = line:match('^([^\t]+)\t([^\t]+)$')
        if word and emoji then
          if not map[word] then map[word] = {} end
          map[word][#map[word] + 1] = emoji
        end
      end
    end
    f:close()
  end
  EMOJI_ASSOC = map
  return map
end

-- ---- 配置 ----
local cfg_loaded = false
local function load_config(env)
  if cfg_loaded then return end
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
  v = cfg:get_bool('predict_next/mix_quick')
  if v ~= nil then MIX_QUICK = v end
  v = cfg:get_bool('predict_next/mix_emoji')
  if v ~= nil then MIX_EMOJI = v end
  local n
  n = cfg:get_int('predict_next/mix_page_size')
  if n and n > 0 then MIX_PAGE_SIZE = n end
  n = cfg:get_int('predict_next/mix_real_keep')
  if n and n > 0 then MIX_REAL_KEEP = n end
  n = cfg:get_int('predict_next/mix_punct_max')
  if n and n >= 0 then MIX_PUNCT_MAX = n end
  n = cfg:get_int('predict_next/mix_quick_max')
  if n and n >= 0 then MIX_QUICK_MAX = n end
  n = cfg:get_int('predict_next/mix_emoji_max')
  if n and n >= 0 then MIX_EMOJI_MAX = n end
  n = cfg:get_int('predict_next/mix_kaomoji_max')
  if n and n >= 0 then MIX_KAOMOJI_MAX = n end
  n = cfg:get_int('predict_next/inputting_min_len')
  if n and n > 0 then INPUTTING_MIN_LEN = n end
  n = cfg:get_int('predict_next/max_user_next')
  if n and n > 0 then MAX_USER_NEXT = n end
  cfg_loaded = true
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
  -- 扩展词库主题级并入（与 segment_phrase 一致，幂等）
  local ok_cfg, words_ext_cfg = pcall(require, 'words_ext_config')
  local ext_cfg = ok_cfg and type(words_ext_cfg) == 'table' and words_ext_cfg or {}
  local ext_themes = { 'chengyu', 'renming', 'yixue', 'dili' }
  for _, theme in ipairs(ext_themes) do
    if ext_cfg[theme] ~= false then
      local ok_t, t = pcall(require, 'words_ext_' .. theme)
      if ok_t and type(t) == 'table' then
        for w, f in pairs(t) do
          words[w] = f
        end
      end
    end
  end
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
local function should_show(w, env, recent_set)
  if not w or w == '' then return false end
  local chars = 0
  for _ in w:gmatch("[\1-\127\194-\244][\128-\191]*") do chars = chars + 1 end
  if chars == 0 then return false end
  -- 排除部首/笔画符号单字（用户要求：部首不参与预测）
  if chars == 1 and NON_WORD_CHARS[w] then
    return false
  end
  -- 词库存在性：words 有权重，或每个字都能查笔画码（用户历史词必然可输）
  local wf = words[w] or 0
  if wf <= 0 then
    if not stroke_of(w) then return false end
  end
  if is_demoted(w) then return false end
  if recent_set and recent_set[w] then return false end
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
  -- 注入候选必须自带 preedit：librime 的 Composition::GetPreedit 对高亮段显示
  -- 「高亮候选的 preedit」，为空时回退显示原始编码（数字）。注入的候选若不设置
  -- preedit，一旦被高亮，预编辑区就会冒出数字码。
  local full = (ctx and ctx.input) or inpt
  local function stroke_symbol(str)
    if not str or str == '' then return '' end
    return (str:gsub("1", "一"):gsub("2", "丨"):gsub("3", "丿")
               :gsub("4", "丶"):gsub("5", "乛"):gsub("[^一丨丿丶乛']", "？"))
  end
  local function new_cand(text)
    local c = Candidate('predict_next', s, e, text, '')
    local st, en = tonumber(s) or 0, tonumber(e) or 0
    if en > st and en <= #full then
      c.preedit = stroke_symbol(full:sub(st + 1, en))
    else
      c.preedit = ''
    end
    return c
  end
  -- 最近上屏集合（排除刚上屏的两个词，避免「刚打完又推荐同一个」）
  local recent = (learning.get_recent_commits and learning.get_recent_commits()) or {}
  local recent_set = {}
  for i = #recent, math.max(1, #recent - 1), -1 do
    recent_set[recent[i]] = true
  end

  -- 阶段 0：用户三元组（前两个上屏词 -> 下一个词）——最个性化的上下文
  local injected = 0
  if inpt == '' and type(ngram.get_prev2) == 'function' and type(ngram.next_words3) == 'function' then
    local p2 = ngram.get_prev2()
    if p2 and p2 ~= '' and p2 ~= last then
      local ok3, list3 = pcall(function() return ngram.next_words3(p2, last, env) end)
      if ok3 and type(list3) == 'table' then
        local n0 = 0
        for _, item in ipairs(list3) do
          local w = item.word
          if w and w ~= last and not seen[w] and should_show(w, env, recent_set) then
            seen[w] = true
            injected = injected + 1
            n0 = n0 + 1
            yield(new_cand(w))
            if n0 >= 2 then break end
          end
        end
      end
    end
  end

  -- 阶段 1：用户 bigram 个性化候选（排最前）
  if last and last ~= '' then
    local user_list = user_next_words(last, env)
    if inpt == '' then
      -- submitted 态：直出最个性化的历史搭配（有上限，防个人搭配刷满候选区）
      local n = 0
      for _, item in ipairs(user_list) do
        local w = item.word
        if w and w ~= last and not seen[w] and should_show(w, env, recent_set) then
          seen[w] = true
          injected = injected + 1
          n = n + 1
          yield(new_cand(w))
          if n >= MAX_USER_NEXT then break end
        end
      end
    elseif INPUTTING_FUSION and #inpt >= INPUTTING_MIN_LEN then
      -- inputting 态：只输出能匹配当前笔画前缀的用户历史后接词。
      -- 注意：短码（1~2 笔）不融合——那几位是「首两笔选字」的黄金位置，
      -- 历史词插进去会挤掉同码高频字（这正是此前短码候选被抢占的同类问题）。
      local n = 0
      for _, item in ipairs(user_list) do
        local w = item.word
        if w and w ~= last and not seen[w] and should_show(w, env, recent_set) then
          local code = stroke_of(w)
          if code and code:sub(1, #inpt) == inpt then
            seen[w] = true
            n = n + 1
            yield(new_cand(w))
            if n >= 2 then break end
          end
        end
      end
    end
  end

  -- 阶段 2：现有候选（用户词已输出的则去重跳过）
  local rest = {}
  for _, cand in ipairs(existing) do
    local text = get_cand_text(cand)
    if not text or not seen[text] then
      if text then seen[text] = true end
      rest[#rest + 1] = cand
    end
  end

  -- 阶段 3（submitted 态混合候选）：在首页预算内追加
  --   预算 = MIX_PAGE_SIZE - min(真实候选数, MIX_REAL_KEEP)
  --   即：真实联想最多占首页 6 个名额，剩下 3 个才给 快捷项；
  --   真实联想不足 6 个时，快捷项补满首页（首次使用也不会空白）。
  --   注意：快捷项必须插在首页内（前 6 个真实联想之后），不能像旧版那样全部排在
  --   所有真实联想之后——那样快捷项会被挤到第 2、3 页，等于没出现。
  -- 首页保留的真实联想个数（扣除阶段 1 已输出的个性化候选）
  local hold = #rest
  if inpt == '' then
    hold = math.min(#rest, math.max(0, MIX_REAL_KEEP - injected))
  end
  for i = 1, hold do yield(rest[i]) end

  if inpt == '' then
    local budget = MIX_PAGE_SIZE - injected - hold
    if budget > 0 then
      local function push(text)
        if budget <= 0 or not text or text == '' then return end
        if seen[text] then return end
        seen[text] = true
        budget = budget - 1
        yield(new_cand(text))
      end
      -- ① 词→emoji（与刚上屏的词强相关，信息量最高）
      if MIX_EMOJI and MIX_EMOJI_MAX > 0 then
        local emoji_map = load_emoji_assoc()
        local emoji_list = emoji_map and emoji_map[last]
        if emoji_list then
          for i = 1, math.min(#emoji_list, MIX_EMOJI_MAX) do push(emoji_list[i]) end
        end
      end
      -- ② 常用标点（句子收尾，配合标点顶字）
      if MIX_PUNCT and MIX_PUNCT_MAX > 0 then
        for i = 1, math.min(#PUNCT_LIST, MIX_PUNCT_MAX) do push(PUNCT_LIST[i]) end
      end
      -- ③ 常用语（对标讯飞常用语面板：高频回复少打几个字）
      if MIX_QUICK and MIX_QUICK_MAX > 0 then
        for i = 1, math.min(#QUICK_PHRASES, MIX_QUICK_MAX) do push(QUICK_PHRASES[i]) end
      end
      -- ④ 颜文字（纯装饰，预算最后）
      if MIX_KAOMOJI and MIX_KAOMOJI_MAX > 0 then
        for i = 1, math.min(#KAOMOJI_LIST, MIX_KAOMOJI_MAX) do push(KAOMOJI_LIST[i]) end
      end
    end
  end

  -- 剩余真实联想（第 2 页起）
  for i = hold + 1, #rest do yield(rest[i]) end
end

-- 兼容 librime-lua：lua_filter 模块返回表，librime 调用表的 func 字段
return { func = filter }