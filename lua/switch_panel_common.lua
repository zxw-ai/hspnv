-- 功能开关面板 · 公共模块（switch_panel_common）
-- ============================================================================
-- 被 switch_panel（处理器）/ switch_panel_t（翻译器）/ switch_panel_f（过滤器）
-- 三个模块共享：面板标记、标题、面板项定义、状态读取/切换工具。
--
-- 注意：librime-lua 对 processor/translator/filter 统一调用模块的「func」字段，
-- 因此必须拆分为独立模块，每个模块各自提供 func。
-- ============================================================================

local M = {}

-- 面板输入标记：两个斜杠（不在笔画 alphabet 内，正常打字不会产生）
M.PANEL_INPUT = '//'

-- 面板标题（显示在预编辑区）
M.PANEL_TITLE = '⚙ 功能设置'

-- 面板项定义：
--   name   = 候选文本（功能名，简短）
--   option = 对应 Rime switch 选项
--   off/on = 关闭/开启时的状态注释
--   multi  = 多状态循环（简繁组：简体/通繁/港繁/臺繁）
--   options= multi 各状态对应的 option 名（第一个为空=全关）
M.PANEL_ITEMS = {
  { name = '联想',         option = 'prediction',              off = '关',     on = '开' },
  { name = '上下文调频',   option = 'context_reorder',         off = '关',     on = '开' },
  { name = '笔画纠错',      option = 'correction_stroke',       off = '关',     on = '开' },
  { name = '自动上屏',      option = 'high_conf_auto_select',   off = '仅唯一', on = '高置信' },
  { name = '模糊笔画',      option = 'fuzzy_stroke',            off = '标准',   on = '模糊' },
  { name = '字符集',       option = 'charset_filter',          off = '大字集', on = '小字集' },
  { name = '标点',         option = 'ascii_punct',             off = '中标',   on = '英标' },
  { name = '中英',         option = 'ascii_mode',              off = '中文',   on = '西文' },
  { name = '简繁',         multi = { '简体', '通繁', '港繁', '臺繁' }, options = { '', 's2t', 's2hk', 's2tw' } },
}

-- 简繁组 option 列表
M.TRAD_OPTIONS = { 's2t', 's2hk', 's2tw' }

-- 读取简繁当前索引（0=简体，1=通繁，2=港繁，3=臺繁）
function M.get_trad_index(ctx)
  for i, opt in ipairs(M.TRAD_OPTIONS) do
    local v = false
    pcall(function() v = ctx:get_option(opt) end)
    if v then return i end
  end
  return 0
end

-- 读取某项当前状态注释
function M.get_state(ctx, item)
  if item.multi then
    return item.multi[M.get_trad_index(ctx) + 1]
  end
  local v = false
  pcall(function() v = ctx:get_option(item.option) end)
  return v and item.on or item.off
end

-- 切换某项
function M.toggle_item(ctx, item)
  if item.multi then
    local cur = M.get_trad_index(ctx)
    local nxt = (cur + 1) % #item.multi
    for _, opt in ipairs(M.TRAD_OPTIONS) do
      pcall(function() ctx:set_option(opt, false) end)
    end
    if nxt > 0 then
      pcall(function() ctx:set_option(item.options[nxt + 1], true) end)
    end
    return
  end
  local v = false
  pcall(function() v = ctx:get_option(item.option) end)
  pcall(function() ctx:set_option(item.option, not v) end)
end

return M