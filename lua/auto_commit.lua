-- 自动上屏（键道顶功模式 + 高置信首位自动上屏）：
-- 1. 唯一候选：当前菜单已就绪且候选唯一时，直接 commit() 上屏高亮候选（键道顶功）。
-- 2. 高置信首位（对标讯飞 p_autoSelectAllIfNeed）：候选不唯一但「首位候选置信度 >= 阈值」时，
--    即使存在多个同码候选也提交首位。置信度由 segment_phrase.get_auto_select_first 计算
--    （首位权重占同码精确候选总权重的比例，权重口径 = 用户频次*步长 + 静态字频）。
-- 处理器在 speller 之前运行，此时 menu 是上一键生成的（已就绪），commit() 提交的是候选文本（正确）。
-- 触发节奏：输入完整码生成候选后，用户输入下一个键时自动上屏（顶功连续输入）。
--
-- 开关（schema）：
--   auto_commit:
--     enable: true              # 总开关
--     high_conf: true           # 高置信首位自动上屏总开关（默认开）
--     high_conf_threshold: 0.6  # 首位置信度阈值（0~1，越大越保守）
--   switches 中 high_conf_auto_select（reset: 1）可随时切换「仅唯一候选 / 高置信首位」。
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
  if not c1 then return 2 end

  -- 只允许「纯汉字」候选自动上屏：
  -- 笔画方案里有几类候选绝不能自动上屏——
  --   (1) 无效输入的兜底候选（如 4500 -> 「丶乛？？」）
  --   (2) 预编辑用的符号串、分词符本身
  -- 否则用户打个错码就会眼睁睁看它把符号串插进文本。
  local function all_cjk(text)
    if not text or text == '' then return false end
    local i, n = 1, #text
    while i <= n do
      local b = text:byte(i)
      local len = 1
      if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 elseif b >= 0xC0 then len = 2 end
      if len ~= 3 then return false end          -- ASCII/2字节/4字节一律拒绝
      local c1, c2_, c3 = text:byte(i, i + 2)
      if not c1 or not c2_ or not c3 then return false end
      local cp = (c1 - 0xE0) * 4096 + (c2_ - 0x80) * 64 + (c3 - 0x80)
      if cp < 0x4E00 or cp > 0x9FFF then return false end   -- 只收基本汉字区
      i = i + 3
    end
    return true
  end

  local function cand_text(c)
    local t = nil
    pcall(function() t = c.text end)
    if not t then pcall(function() t = c:get_text() end) end
    return t
  end

  -- 唯一候选：直接提交（键道顶功原有行为），但仅限纯汉字候选
  if not c2 then
    if all_cjk(cand_text(c1)) then
      pcall(function() ctx:commit() end)
    end
    return 2
  end

  -- 候选不唯一：尝试高置信首位自动上屏
  local high_conf = false
  local threshold = 0.6
  -- 方案开关（switch high_conf_auto_select，默认开）
  pcall(function()
    if ctx.get_option then
      local v = ctx:get_option('high_conf_auto_select')
      if v ~= nil then high_conf = v end
    end
  end)
  -- 配置总开关
  if config then
    local ok, v = pcall(function() return config:get_bool('auto_commit/high_conf') end)
    if ok and v ~= nil then high_conf = high_conf and v end
    local ok2, t = pcall(function() return config:get_double('auto_commit/high_conf_threshold') end)
    if ok2 and t and t > 0 and t < 1 then threshold = t end
  end
  if not high_conf then return 2 end

  -- 惰性加载 segment_phrase（主翻译器已缓存，无额外加载开销）
  local segp = nil
  pcall(function() segp = require('segment_phrase') end)
  if not segp or type(segp.get_auto_select_first) ~= 'function' then return 2 end

  local info = nil
  pcall(function() info = segp.get_auto_select_first(input, env) end)
  if info and info.text == cand_text(c1) and info.conf and info.conf >= threshold
     and all_cjk(info.text) then
    -- 高置信首位：提交首位候选（正确文本，非原始输入码）
    pcall(function() ctx:commit() end)
  end
  -- 返回 2（不消费按键），让当前按键继续被 speller 处理（顶功连续输入）
  return 2
end

return M