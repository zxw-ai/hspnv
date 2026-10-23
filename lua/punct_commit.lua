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

local function keycode_of(key_event)
  if type(key_event) == 'number' then return key_event end
  local code = nil
  pcall(function() code = key_event.keycode end)
  return code
end

local function is_punct_key(key_event)
  local code = keycode_of(key_event)
  if not code then return false end
  local shift = false
  pcall(function() shift = key_event.shift end)
  if shift then
    return PUNCT_SHIFT[code] == true
  end
  return PUNCT_BASE[code] == true
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

  -- 仅对标点键生效
  if not is_punct_key(key_event) then return 2 end

  local ctx = env.engine and env.engine.context
  if not ctx then return 2 end

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