-- 功能开关面板 · 过滤器（switch_panel_f）
-- ============================================================================
-- 面板模式（输入为 //）时：
--   1. 丢弃其他翻译器/过滤器产生的普通候选，只保留 switch_panel 候选；
--   2. 再次设置预编辑区标题（覆盖 filter_seg_count 等设置的笔画符号）。
-- 非面板模式：完全透传，不影响正常输入。
--
-- 挂载：filters: - lua_filter@*switch_panel_f
-- ============================================================================

local common = require('switch_panel_common')

local function filter(input, env)
  local ctx = env.engine and env.engine.context
  local inpt = ''
  if ctx then pcall(function() inpt = ctx:get_input() or '' end) end

  if inpt ~= common.PANEL_INPUT then
    -- 正常透传
    for cand in input:iter() do yield(cand) end
    return
  end

  -- 面板模式：设置标题（覆盖前面过滤器设置的笔画符号）
  local seg = nil
  if ctx then
    pcall(function() seg = ctx.composition:back() end)
  end
  if seg then
    pcall(function() seg.preedit = common.PANEL_TITLE end)
  end

  -- 只保留面板候选
  for cand in input:iter() do
    if cand.type == 'switch_panel' then
      yield(cand)
    end
  end
end

-- 兼容 librime-lua：lua_filter 模块返回表，librime 调用表的 func 字段
return { func = filter }