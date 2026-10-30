-- lua/filter_seg_count.lua
-- 1. 空输入状态（上屏后的持续联想阶段，inpt == ""）：100% 全量放行所有后接联想词，支持无限连击成句！
-- 2. 空分词状态（以 ' 结尾，如 31' 或 31'32'）：放行所有后接高频联想词（不限字数）；
-- 3. 具体分词多段输入（末尾不是 '，如 31'32）：严格锁定字数等于段数（1个分词=两字词，2个分词=三字词）。
-- 4. 【强保险】所有放行候选强制清理：comment 一律清空、preedit 一律笔画符号，杜绝任何数字出现在候选词后面/顶部。

local function char_count(text)
  if not text or text == "" then return 0 end
  local n = 0
  for _ in text:gmatch("[\1-\127\194-\244][\128-\191]*") do
    n = n + 1
  end
  return n
end

-- 兼容获取候选文本：优先 cand.text，兼容 cand:get_text()，绝不因方法不存在而报错吞候选！
local function get_cand_text(cand)
  if cand.text and cand.text ~= "" then
    return cand.text
  end
  if type(cand.get_text) == "function" then
    local ok, text = pcall(function() return cand:get_text() end)
    if ok and text and text ~= "" then
      return text
    end
  end
  return nil
end

-- 笔画符号转换与「各段 preedit 设置」已抽到 lua/preedit_util.lua（与 segment_phrase 共用同一实现）
local preedit_util = require('preedit_util')
local function to_stroke_symbol(s) return preedit_util.to_stroke_symbol(s) end
local function force_preedit(env, inpt) preedit_util.set_preedit(env, inpt) end

local function clean_cand(cand, raw)
  local text = get_cand_text(cand)
  if not text then return cand end
  local ok, c = pcall(function()
    local nc = Candidate(cand.type, cand.start, cand._end, text, '')
    -- 预编辑兜底：
    --   ① 空 → 用整串输入转符号；
    --   ② 含数字（0-9，例如 custom_phrase 简码候选的原始编码 "31"）→ 同样重建。
    -- 否则高亮这类候选时，librime 会把「31」直接显示在预编辑区。
    local preedit = cand.preedit
    if not preedit or preedit == '' or preedit:find('[0-9]') then
      preedit = to_stroke_symbol(raw or '')
    end
    nc.preedit = preedit
    return nc
  end)
  if ok and c then
    return c
  end
  return cand
end

local function filter(input, env)
  local ctx = env.engine and env.engine.context
  local inpt = ctx and ctx.input or ""

  -- 计算模式保留原始算式与结果，不转笔画或按字数过滤。
  if inpt:sub(1, 1) == 'V' then
    local expr = inpt:gsub('V', '')

    -- 隐藏 composition preedit 中的 V 前缀（顶部只显示表达式原文）
    local comp = ctx.composition
    if comp then
      local seg = comp:back()
      if seg then
        seg.preedit = expr
      end
    end

    for cand in input:iter() do
      if cand.type == 'calculator' or cand.type == 'calculator_expression' then
        local ok, nc = pcall(function()
          local c = Candidate(cand.type, cand.start, cand._end, cand.text, cand.comment or '')
          c.preedit = expr
          return c
        end)
        if ok and nc then yield(nc) else yield(cand) end
      end
    end
    return
  end

  -- 强制顶部 preedit 显示笔画符号（323'53 -> 丿丨丿'乛丿），不显示阿拉伯数字
  force_preedit(env, inpt)

  -- 核心保障 1: 如果当前输入为空（字词刚上屏，进入连续联想阶段），无条件放行所有联想候选！
  if inpt == "" then
    for cand in input:iter() do
      yield(clean_cand(cand, inpt))
    end
    return
  end

  -- 核心保障 2: 如果输入末尾是分词符 '，处于“空分词连打联想模式”，放行所有高频词！
  if inpt:sub(-1, -1) == "'" then
    for cand in input:iter() do
      yield(clean_cand(cand, inpt))
    end
    return
  end

  local segs = 0
  for _ in inpt:gmatch("'") do segs = segs + 1 end

  -- 没有分词（单字模式），原样输出
  if segs == 0 then
    for cand in input:iter() do
      yield(clean_cand(cand, inpt))
    end
    return
  end

  -- 统计有效码段数（以实际笔画段为准，开头/多余的分词符不计入目标词长）
  local parts_count = 0
  for p in inpt:gmatch("[^']+") do
    if p:match("^[12345?]+$") then parts_count = parts_count + 1 end
  end

  -- 纯分词符输入（无有效码段）：全量放行，避免误杀后显示笔画符号
  if parts_count == 0 then
    for cand in input:iter() do
      yield(clean_cand(cand, inpt))
    end
    return
  end

  -- 防爆上限：超过 8 段（9 字及以上）不再锁定词长，全量放行（翻译器侧已不上限，此处避免误杀长候选）
  if parts_count > 8 then
    for cand in input:iter() do
      yield(clean_cand(cand, inpt))
    end
    return
  end

  -- 具体分词输入：严格按照有效码段数精准锁定词长（预测候选无论是 predict 还是 prediction 均无条件放行）
  local target_len = parts_count
  -- 造词模式允许候选只覆盖输入中的一个子段：按候选 start/_end
  -- 重新计算该子段的有效码段数，避免把「我要」等前段词误删。
  local function span_target(cand)
    if (cand.type or '') ~= 'phrase' then return nil end
    local s = tonumber(cand.start) or 0
    local e = tonumber(cand._end) or -1
    if s < 0 or e < s or e >= #inpt then return nil end
    local span = inpt:sub(s + 1, e):gsub("'+$", "")
    local n = 0
    for p in span:gmatch("[^']+") do
      if p:match("^[12345?]+$") then n = n + 1 end
    end
    return n
  end
  local yielded_any = false
  local first_cand = nil
  local passed = {}
  -- 部分回退模式：翻译器已走 fallback_partial（无整词命中，保护前段词+末段定字），
  -- 此时不再按词长过滤，确保「亡羊」等前段词与末段单字都能显示。
  local fallback_mode = false
  if env and env.engine then
    pcall(function() fallback_mode = env.engine._bg5_fallback == true end)
  end
  for cand in input:iter() do
    if not first_cand then first_cand = cand end
    local ctype = cand.type or ""
    -- 部分回退模式下所有候选无条件放行
    if fallback_mode then
      yield(clean_cand(cand, inpt))
      yielded_any = true
    elseif ctype == "predict" or ctype == "prediction" or ctype == "single" or ctype == "stroke_fallback" then
      yield(clean_cand(cand, inpt))
      yielded_any = true
    else
      local text = get_cand_text(cand)
      if text then
        local n = char_count(text)
        -- 词长锁定只对「覆盖整段输入」的候选生效：
        -- 多段 composition 时每个段的候选 end < #inpt，若仍按整串词长过滤，
        -- 单段候选会被全部误杀 → 该段菜单元为空 → 元书回退显示原始数字。
        local cs = tonumber(cand.start) or 0
        local ce = tonumber(cand._end) or -1
        local covers_all = (cs <= 0 and ce >= #inpt)
        local expected_len = span_target(cand)
        if not expected_len then
          if covers_all then
            expected_len = target_len
          elseif n and n == 1 then
            -- 多段 composition：每段只翻译自己的子串，候选不覆盖整串；
            -- 单字候选一律放行，避免整串词长把各段候选误杀成空菜单（→ 回显数字）。
            expected_len = 1
          end
        end
        if not expected_len or (n and n == expected_len) then
          yield(clean_cand(cand, inpt))
          yielded_any = true
        else
          passed[#passed + 1] = cand
        end
      else
        -- 如果无法获取文本，安全起见直接放行，绝不再吞掉候选！
        yield(clean_cand(cand, inpt))
        yielded_any = true
      end
    end
  end
  -- 终极保底：若所有候选都被字数过滤（如造词路径输出的是每段单字候选），
  -- 则全部放行，确保逐字造词时每一段候选字都可见、可上屏！
  if not yielded_any then
    for _, cand in ipairs(passed) do
      yield(clean_cand(cand, inpt))
    end
    if #passed == 0 and first_cand then
      yield(clean_cand(first_cand, inpt))
    end
  end
  -- 死守：翻译器若完全没有产出候选（first_cand 为 nil，如多分词符长输入
  -- 未命中任何字词），也输出一个笔画符号候选，绝不让元书回退显示原始数字码。
  if not first_cand then
    local fallback = {
      type = 'single',
      start = 0,
      _end = #inpt,
      text = to_stroke_symbol(inpt),
    }
    yield(clean_cand(fallback, inpt))
  end
end

return filter