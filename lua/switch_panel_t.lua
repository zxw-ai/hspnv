-- 功能开关面板 · 翻译器（switch_panel_t）
-- ============================================================================
-- 当输入为面板标记 // 时，输出全部功能开关候选：
--   候选文本 = 功能名（简短）
--   候选注释 = 当前状态（开/关/标准/模糊/大字集/…）
-- 并在预编辑区显示标题「⚙ 功能设置」（隐藏 //）。
--
-- 挂载：translators: - lua_translator@*switch_panel_t
-- ============================================================================

local common = require('switch_panel_common')

local M = {}

function M.func(input, seg, env)
  if input ~= common.PANEL_INPUT then return end
  local ctx = env.engine and env.engine.context
  if not ctx then return end

  -- 预编辑区显示标题（隐藏 //）
  pcall(function() seg.preedit = common.PANEL_TITLE end)

  for _, item in ipairs(common.PANEL_ITEMS) do
    local state = common.get_state(ctx, item)
    yield(Candidate('switch_panel', seg.start, seg._end, item.name, state))
  end
end

return M