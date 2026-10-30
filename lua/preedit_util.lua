-- preedit_util.lua —— 预编辑（顶部笔画串）统一实现
-- 供 segment_phrase 与 filter_seg_count 共用，避免两份实现漂移（P1 重构，2026-10-30）。
--
-- 关键点（踩过两次坑）：
--   1) lua_translator 收到的 input 是「当前段」子串（librime 的 TranslateSegments 传
--      input.substr(segment.start, len)），而 seg.start/_end 是整串坐标 →
--      必须用 ctx.input 截取，否则越界、该段 preedit 不设置，元书回显原始数字。
--   2) Composition::GetPreedit 对「非末段」显示首候选文本、对「末段」显示高亮候选的 preedit；
--      所以每段都必须有候选，且候选要带 preedit。
local M = {}

-- 笔画符号转换：1-5 → 一丨丿丶乛，' 保留，其余字符 → ？（绝不出现阿拉伯数字）
function M.to_stroke_symbol(s)
  if not s then return "" end
  return s:gsub("1", "一"):gsub("2", "丨"):gsub("3", "丿"):gsub("4", "丶"):gsub("5", "乛")
          :gsub("[^一丨丿丶乛']", "？")
end

-- 把 composition 各段的 preedit 都设为笔画符号；预测段（st==en）清空
function M.set_preedit(env, inpt)
  if not env or not inpt then return end
  local ctx = env.engine and env.engine.context
  if not ctx then return end
  local comp = ctx.composition
  if not comp or comp:empty() then return end
  -- 以整串为准（translator 的 input 可能只是段子串）
  local full = inpt
  local ok_in, ci = pcall(function() return ctx.input end)
  if ok_in and type(ci) == 'string' and #ci >= #inpt then full = ci end
  local function apply(seg)
    if not seg then return end
    local st, en = nil, nil
    pcall(function()
      st = seg.start
      en = seg._end
    end)
    if st == nil then
      pcall(function() st = seg._start end)
    end
    if st == nil or en == nil then return end
    if en > st and st >= 0 and en <= #full then
      local sub = full:sub(st + 1, en)
      pcall(function() seg.preedit = M.to_stroke_symbol(sub) end)
    elseif st == en then
      pcall(function() seg.preedit = '' end)
    end
  end
  local ok, segm = pcall(function() return comp:toSegmentation() end)
  if ok and segm then
    local ok2, segs = pcall(function() return segm:get_segments() end)
    if ok2 and type(segs) == 'table' then
      for _, s in ipairs(segs) do apply(s) end
    end
  end
  local ok3, segs3 = pcall(function() return comp:get_segments() end)
  if ok3 and type(segs3) == 'table' then
    for _, s in ipairs(segs3) do apply(s) end
  end
  apply(comp:back())
end

return M
