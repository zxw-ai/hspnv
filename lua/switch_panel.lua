-- 功能开关面板 · 处理器（switch_panel）
-- ============================================================================
-- 监听皮肤「功能切换」键（发送 F4）：
--   F4       → 打开/关闭面板（把输入设为面板标记 //）
--   数字 1~9 → 切换对应开关（面板打开时，状态即时刷新）
--   Esc/F4   → 关闭面板
--   其他键   → 关闭面板并放行（进入正常输入）
--
-- 挂载：processors: - lua_processor@*switch_panel
-- ============================================================================

local common = require('switch_panel_common')

local M = {}

function M.func(key_event, env)
  local ctx = env.engine and env.engine.context
  if not ctx then return 2 end

  local repr = ''
  pcall(function() repr = key_event:repr() or '' end)
  local kc = key_event.keycode or 0

  local input = ''
  pcall(function() input = ctx:get_input() or '' end)

  -- F4：打开/关闭面板
  if repr == 'F4' or repr == 'f4' or kc == 0xffc1 then
    if input == common.PANEL_INPUT then
      pcall(function() ctx:clear() end)
    else
      pcall(function() ctx:clear() end)
      pcall(function() ctx:push_input('/') end)
      pcall(function() ctx:push_input('/') end)
    end
    return 1  -- kAccepted
  end

  -- 面板打开时
  if input == common.PANEL_INPUT then
    -- 数字键 1~9：切换对应开关
    if kc >= 0x31 and kc <= 0x39 then
      local item = common.PANEL_ITEMS[kc - 0x30]
      if item then
        common.toggle_item(ctx, item)
        pcall(function() ctx:refresh_non_confirmed_composition() end)
      end
      return 1  -- 消费数字键，不让 selector 上屏
    end
    -- Esc：关闭面板
    if repr == 'Escape' or repr == 'escape' or kc == 0xff1b then
      pcall(function() ctx:clear() end)
      return 1
    end
    -- 其他键：关闭面板并放行
    pcall(function() ctx:clear() end)
    return 2
  end

  return 2  -- kNoop
end

return M