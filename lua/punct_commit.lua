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
-- 无 Shift：, . / ;
local PUNCT_BASE = {
  [0x2c] = true,  -- ,
  [0x2e] = true,  -- .
  [0x2f] = true,  -- /
  [0x3b] = true,  -- ;
}
-- 带 Shift：; -> :   / -> ?   1 -> !
local PUNCT_SHIFT = {
  [0x3b] = true,  -- :
  [0x2f] = true,  -- ?
  [0x31] = true,  -- !
}
-- 全角标点字符（符号键盘/文本方式到达，如「。 」等）
local FULL_PUNCT = {
  ['，'] = true, ['。'] = true, ['？'] = true, ['！'] = true,
  ['：'] = true, ['；'] = true, ['、'] = true, ['～'] = true,
  ['……'] = true, ['—'] = true,
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
  -- 全角标点字符（元书符号键盘可能以字符方式发送）
  local ch = ''
  pcall(function()
    if key_event.character then ch = key_event.character end
  end)
  if FULL_PUNCT[ch] then return true end
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

-- 提交文本（兼容 engine:commit_text / ctx:commit_text）
local function commit_text(env, ctx, text)
  local ok = false
  pcall(function()
    if env.engine and env.engine.commit_text then
      env.engine:commit_text(text)
      ok = true
    end
  end)
  if not ok then
    pcall(function() ctx:commit_text(text) end)
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

  -- 输入为空则不顶字（直接让标点正常上屏）
  local input = ''
  pcall(function() input = ctx:get_input() or '' end)
  if input == '' then return 2 end

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
    -- 提交高亮候选（正确文本，非原始输入码）
    pcall(function() ctx:commit() end)
    -- 返回 2（不消费按键）：commit 后 input 已清空，当前标点键继续被正常处理上屏
  end
  return 2
end

return M