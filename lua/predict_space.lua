-- predict_space.lua: 连打键上屏联想词（联想空格接力，独立连打键）
-- 移植自万象 super_processor 的 enable_predict_space 机制。
-- 原理：
--   上屏一个词后，候选区出现联想候选；按连打键（默认回车 Return）直接上屏第一个联想候选。
--   关键：用 ctx:set_option("_dummy_predict_update", true) 触发一次 Rime 上下文刷新，
--   让 predictor/segment_phrase 基于新的联想上下文生成下一轮联想候选（连打不中断）。
--   空格键保持 Rime 原生行为（输入中确认候选、空输入上屏空格），不与连打键冲突。
-- 挂载：lua_processor@*predict_space
-- 配置：
--   predict_space:
--     enable: true     # 是否启用连打
--     key: "Return"     # 连打键（默认回车 Return；可选 Tab/Space）

local KEYCODES = {
  space = 0x20,
  tab = 0xFF09,
  Return = 0xFF0D,
  Enter = 0xFF0D,
}

local M = {}

function M.init(env)
  env.enable_predict_space = true
  env.predict_keycode = 0xFF0D  -- 默认回车 Return
  env._predict_space_pending = false
  local config = env.engine and env.engine.schema and env.engine.schema.config
  if config then
    local ok, v = pcall(function() return config:get_bool('predict_space/enable') end)
    if ok and v ~= nil then env.enable_predict_space = v end
    local okk, k = pcall(function() return config:get_string('predict_space/key') end)
    if okk and k then
      local kc = KEYCODES[k:lower()]
      if kc then env.predict_keycode = kc end
    end
  end
  -- 连接 update_notifier，在 Rime 完成这次上下文更新后复位虚拟 option
  if env.engine and env.engine.context and env.engine.context.update_notifier then
    env._predict_space_conn = env.engine.context.update_notifier:connect(function()
      if env._predict_space_pending then
        env._predict_space_pending = false
        pcall(function() env.engine.context:set_option('_dummy_predict_update', false) end)
      end
    end)
  end
end

function M.func(key_event, env)
  -- 只处理连打键（默认回车 Return；不再拦截空格，空格保持 Rime 原生行为）
  if key_event.keycode ~= (env.predict_keycode or 0xFF0D) then return 2 end
  if not env.enable_predict_space then return 2 end
  local ctx = env.engine and env.engine.context
  if not ctx then return 2 end

  -- 输入框有字 = 正在输入：放行（不干预，回车仍走原生提交）
  local input = ''
  pcall(function() input = ctx:get_input() or '' end)
  if input ~= '' then
    return 2
  end

  -- 空输入状态：用 learning 判断是否处于联想状态（刚上屏过词）
  -- 注意：共享实例挂在 env.engine 上（所有 Lua 组件共享同一 engine）；require 可能返回隔离新实例
  local learning = (env.engine and env.engine.bg5_learning) or env.bg5_learning or require('learning')
  local last_commit = learning and learning.get_last_commit() or ''
  if not last_commit or last_commit == '' then
    return 2  -- 无联想上下文：放行（回车走原生行为）
  end

  -- 1. 优先原生提交：select(0) 选中当前候选 → 检查 commit_text 非空 → commit()。
  --    原生 commit 会写 Rime commit_history，predictor 能基于新词生成下一轮联想（连打不中断）。
  local native_ok = false
  pcall(function()
    if ctx:select(0) then
      local ct = ctx:get_commit_text() or ''
      if ct ~= '' then
        ctx:commit()
        native_ok = true
      end
    end
  end)
  if native_ok then
    return 1  -- 连打键被消费，联想由 Rime 自动更新
  end

  -- 2. 原生失败（placeholder 段候选不可用）：用我们自己的联想模型生成下一个词
  --    共享实例挂在 env.engine 上；require 可能返回隔离新实例（状态为空）
  local seg_phrase = (env.engine and env.engine.bg5_segment_phrase) or env.bg5_segment_phrase or require('segment_phrase')
  local text = nil
  if seg_phrase and seg_phrase.get_predict_continuations then
    local ok, list = pcall(function()
      return seg_phrase.get_predict_continuations(env)
    end)
    if ok and list and list[1] and list[1] ~= '' then
      text = list[1]
    end
  end

  if text then
    -- 上屏联想词
    pcall(function() ctx:commit_text(text) end)
    -- 更新联想上下文（learning 记录刚上屏的词）
    pcall(function() learning.notify_commit(text, env) end)
    -- 触发候选刷新（万象机制：虚拟 option 触发 update notifier）
    env._predict_space_pending = true
    pcall(function() ctx:set_option('_dummy_predict_update', true) end)
  end
  return 1  -- 连打键被消费，用于联想上屏
end

return M