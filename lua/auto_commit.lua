-- 自动上屏（键道顶功模式）：输入中，当前菜单已就绪且候选唯一时，直接 commit() 上屏高亮候选。
-- 处理器在 speller 之前运行，此时 menu 是上一键生成的（已就绪），commit() 提交的是候选文本（正确）。
-- 触发节奏：输入最后一码生成唯一候选后，用户输入下一个键时自动上屏前一个唯一候选（顶功连续输入）。
local M = {}

function M.func(key_event, env)
  local config = env.engine and env.engine.schema and env.engine.schema.config
  local enabled = false
  if config then
    local ok, v = pcall(function() return config:get_bool('auto_commit/enable') end)
    if ok and v ~= nil then enabled = v end
  end
  if not enabled then return 2 end

  local ctx = env.engine and env.engine.context
  if not ctx then return 2 end

  local input = ''
  pcall(function() input = ctx:get_input() or '' end)
  if input == '' then return 2 end

  -- 当前段菜单（上一键生成的，已就绪）
  local seg = nil
  pcall(function() seg = ctx.composition:back() end)
  if not seg or not seg.menu then return 2 end
  if seg.menu:empty() then return 2 end

  local c1, c2 = nil, nil
  pcall(function()
    seg.menu:prepare(2)
    c1 = seg.menu:get_candidate_at(0)
    c2 = seg.menu:get_candidate_at(1)
  end)
  if c1 and not c2 then
    -- menu 就绪且唯一候选：commit() 提交高亮候选（正确文本，非原始输入码）
    pcall(function() ctx:commit() end)
    -- 返回 2（不消费按键），让当前按键继续被 speller 处理（顶功连续输入）
  end
  return 2
end

return M
