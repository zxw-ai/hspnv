-- punct_commit.lua v1: 标点顶字（路线 C：标点顶字 + 自动选首增强）
-- =============================================================================
-- 借鉴讯飞「标点 bigram + 标点顶字」机制：输入中按标点键（，。？！；：等）时，
-- 若当前有候选，先提交高亮候选（通常是首位），再让标点正常上屏。
-- 效果：连续输入时无需空格确认——"词 + 标点"一次完成，句子流畅连贯。
--
-- 与 auto_commit（唯一候选自动上屏）互补：
--   - auto_commit：候选唯一时，任意下一键自动上屏（顶功）
--   - punct_commit：候选不唯一时，按标点键强制提交高亮候选（标点顶字）
--
-- 挂载（schema processors 链，auto_commit 之后）：
--   - lua_processor@*punct_commit
--
-- 配置段：
--   punct_commit:
--     enable: true
--
-- 兼容性：任何一步 API 缺失/异常都返回 2（不消费按键），绝不影响标点正常输入。
-- =============================================================================

local M = {}

-- 标点键码（Rime/X11 keycode）
-- 无 Shift：, . / 以及元书皮肤直接发送的字符键码 ! :
-- 注：Hamster 皮肤 character:'!' 发送 0x21，character:':' 发送 0x3a（不带 Shift）
-- 注意：0x3b（; 分号）不在其中——分号键码保留给「末」键（以词定字取末字），
-- 分号标点输入由顶部符号快捷栏发送全角「；」经 FULL_PUNCT 路径处理。
local PUNCT_BASE = {
  [0x2c] = true,  -- ,
  [0x2e] = true,  -- .
  [0x2f] = true,  -- /
  [0x21] = true,  -- !
  [0x3a] = true,  -- :
}
-- 带 Shift：; -> :   / -> ?
-- 注意：0x31 是数字 1 键的键码，**不是** '!'（'!' 的 keysym 是 0x21）。
-- 之前误把 0x31 列在这里，若元书把数字行按键报告成 shift 状态，按 1 会被当成标点键处理。
-- Shift+1 的 '!' 由 PUNCT_BASE[0x21] 与 character '!' 两条路径覆盖，删掉 0x31 不影响。
local PUNCT_SHIFT = {
  [0x3b] = true,  -- :
  [0x2f] = true,  -- ?
}
-- 全角标点字符（符号键盘/文本方式到达，如「。 」等）
local FULL_PUNCT = {
  ['，'] = true, ['。'] = true, ['？'] = true, ['！'] = true,
  ['：'] = true, ['；'] = true, ['、'] = true, ['～'] = true,
  ['……'] = true, ['—'] = true,
}
-- 半角标点字符 → 对应中文标点（皮肤以 character 方式发送且 keycode 不可用时，
-- Rime punctuator 无法处理，需由本处理器直接上屏全角标点）
-- 注意：分号 ; 不在其中——分号键码（0x3b）保留给「末」键（以词定字取末字），
-- 分号输入由顶部符号快捷栏发送全角「；」经 FULL_PUNCT 路径处理。
local HALF_PUNCT = {
  [','] = '，', ['.'] = '。', ['/'] = '、',
  [':'] = '：', ['?'] = '？', ['!'] = '！',
}

local function keycode_of(key_event)
  if type(key_event) == 'number' then return key_event end
  local code = nil
  pcall(function() code = key_event.keycode end)
  return code
end

local function is_punct_key(key_event)
  local code = keycode_of(key_event)
  if code then
    local shift = false
    pcall(function() shift = key_event.shift end)
    if shift then
      if PUNCT_SHIFT[code] then return true end
    else
      if PUNCT_BASE[code] then return true end
    end
  end
  -- 全角/半角标点字符（元书符号键盘/皮肤可能以字符方式发送）
  local ch = ''
  pcall(function()
    if key_event.character then ch = key_event.character end
  end)
  if FULL_PUNCT[ch] then return true end
  if HALF_PUNCT[ch] then return true end
  return false
end

-- 判断是否为问号键（?）：
-- 元书可能以 Shift+/（keycode 0x2f + shift）、ASCII 0x3f、repr 含 ?、或 character='?' 到达。
local function is_question_key(key_event)
  if type(key_event) ~= 'table' then return false end
  local code = nil
  pcall(function() code = key_event.keycode end)
  local shift = false
  pcall(function() shift = key_event.shift end)
  if code == 0x2f and shift then return true end
  if code == 0x3f then return true end  -- ASCII '?'
  local repr = ''
  pcall(function() repr = key_event:repr() or '' end)
  if repr and repr ~= '' then
    local r = repr:lower()
    if r == '?' or r:find('question') or r:find('shift+slash') then return true end
  end
  local ch = ''
  pcall(function()
    if key_event.character then ch = key_event.character
    elseif key_event.type == 'character' and key_event.value then ch = key_event.value end
  end)
  if ch == '?' then return true end
  return false
end

-- 提交文本（兼容 engine:commit_text / ctx:commit_text，多重兜底确保标点能上屏）
local function commit_text(env, ctx, text)
  local done = false
  pcall(function()
    if env.engine and env.engine.commit_text then
      env.engine:commit_text(text)
      done = true
    end
  end)
  if not done then
    pcall(function()
      if ctx and ctx.commit_text then
        ctx:commit_text(text)
        done = true
      end
    end)
  end
  if not done then
    pcall(function()
      if env.engine and env.engine.context then
        env.engine.context:commit_text(text)
        done = true
      end
    end)
  end
end

function M.func(key_event, env)
  -- 配置开关
  local config = env.engine and env.engine.schema and env.engine.schema.config
  local enabled = false
  if config then
    local ok, v = pcall(function() return config:get_bool('punct_commit/enable') end)
    if ok and v ~= nil then enabled = v end
  end
  if not enabled then return 2 end

  local ctx = env.engine and env.engine.context
  if not ctx then return 2 end

  -- 问号特殊处理：空输入时按 ? 直接上屏全角 ？，避免符号键盘问号被当作笔画通配符。
  -- 若当前已有笔画码（如 31），放行 ? 作为通配符。
  if is_question_key(key_event) then
    local input = ''
    pcall(function() input = ctx:get_input() or '' end)
    if input == '' then
      commit_text(env, ctx, '？')
      return 1  -- 已消费按键
    end
    return 2
  end

  -- 仅对标点键生效
  if not is_punct_key(key_event) then return 2 end

  -- 判断是否为全角标点（符号键盘以字符方式发送，Rime 无法通过键码路径处理）
  local punct_ch = ''
  pcall(function()
    if key_event.character then punct_ch = key_event.character end
  end)
  local is_full_punct = FULL_PUNCT[punct_ch] == true

  -- 输入为空：
  --  - 全角标点：直接上屏标点
  --  - 半角标点（任何 keycode 状态）：直接上屏对应中文标点，确保标点可靠输出
  --    （不依赖 punctuator，避免元书 character 事件 keycode 异常时无输出）
  local input = ''
  pcall(function() input = ctx:get_input() or '' end)
  if input == '' then
    if is_full_punct then
      commit_text(env, ctx, punct_ch)
      return 1
    end
    local full = HALF_PUNCT[punct_ch]
    if full then
      commit_text(env, ctx, full)
      return 1
    end
    return 2
  end

  -- 取当前段菜单（与 auto_commit 相同方式，已就绪）
  local seg = nil
  pcall(function() seg = ctx.composition:back() end)
  if not seg or not seg.menu then return 2 end
  if seg.menu:empty() then return 2 end

  local c1 = nil
  pcall(function()
    seg.menu:prepare(1)
    c1 = seg.menu:get_candidate_at(0)
  end)
  if c1 then
    -- 提交高亮候选：优先 ctx:commit()；若异常则清空并用 commit_text 兜底，
    -- 确保「标点顶字」在任何 Rime 实现下候选都能上屏。
    local committed = false
    pcall(function()
      ctx:commit()
      committed = true
    end)
    if not committed then
      pcall(function() ctx:clear() end)
      commit_text(env, ctx, c1.text)
    end
  end
  if is_full_punct then
    -- 全角标点：直接上屏标点，与候选一起完成「标点顶字」
    commit_text(env, ctx, punct_ch)
    return 1
  end
  -- 半角标点：提交候选后直接上屏对应中文标点（不依赖 punctuator，
  -- 避免元书 character 事件 keycode 异常时标点无法输出）
  local full = HALF_PUNCT[punct_ch]
  if full then
    commit_text(env, ctx, full)
    return 1
  end
  -- 无法映射的标点：返回 2（不消费按键），让 Rime 继续处理
  return 2
end

return M