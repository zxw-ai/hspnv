-- 生成补充词表（按领域），并做「不在库 / 可打 / 长度」三重过滤
-- 用法：cd lua && lua5.3 ../tools/gen_supplement_words.lua /tmp/dom /tmp/supplement.txt
package.path = './?.lua;' .. package.path

local DIR = arg[1] or '/tmp/dom'
local OUT = arg[2] or '/tmp/supplement.txt'

local words = require('words')
local stroke = require('stroke')

local function utf8_chars(s)
  local t = {}
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
  return t
end
local function usable(w, minlen, maxlen)
  local chars = utf8_chars(w)
  if #chars < minlen or #chars > maxlen then return false end
  for _, ch in ipairs(chars) do
    local b = ch:byte(1)
    if not b or b < 0xE4 or b > 0xE9 then return false end  -- 纯汉字
    if not stroke[ch] then return false end                 -- 笔画表可打
  end
  return true
end

-- 队名/人名音译常见字（用于排除体育词表里的球队与球员）
local NAME_CHARS = '斯尔堡洛佛基茨瓦泽雷尼夫特曼森纳姆拉那'
local function looks_like_name(w)
  local n = 0
  for ch in w:gmatch("[\1-\127\194-\244][\128-\191]*") do
    if NAME_CHARS:find(ch, 1, true) then n = n + 1 end
  end
  return n >= 2 or w:find('联$') or w:find('队$') or w:find('城$') or w:find('港$')
end

local seen, out, counts = {}, {}, {}
local function add(w, cat)
  if seen[w] or words[w] then return false end
  if not usable(w, 2, 4) then return false end
  seen[w] = true
  out[#out + 1] = w .. '\t' .. cat
  counts[cat] = (counts[cat] or 0) + 1
  return true
end

local function load_rows(path)
  local rows = {}
  local f = io.open(path, 'r')
  if not f then return rows end
  for line in f:lines() do
    local w, n = line:match('^([^\t]+)\t(%d+)$')
    if w then rows[#rows + 1] = { w = w, n = tonumber(n) } end
  end
  f:close()
  table.sort(rows, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.w < b.w
  end)
  return rows
end

-- ① 法律诉讼：词表质量最好，直接取 2~4 字
local law = load_rows(DIR .. '/法律诉讼.txt')
local n_law = 0
for _, r in ipairs(law) do
  if n_law >= 250 then break end
  if add(r.w, '法律') then n_law = n_law + 1 end
end

-- ② 餐饮食品：词表里生僻菜名/品牌名太多，改用精选常见菜名与食材
local FOOD = {
  '红烧肉','糖醋排骨','宫保鸡丁','麻婆豆腐','鱼香肉丝','回锅肉','水煮鱼','酸菜鱼','毛血旺',
  '白灼虾','小龙虾','烤鸭','烧鹅','叉烧','肠粉','云吞','馄饨','汤圆','粽子','月饼','年糕',
  '锅贴','生煎','小笼包','灌汤包','煎饺','蒸饺','油条','豆浆','豆腐脑','煎饼','手抓饼',
  '鸡蛋灌饼','肉夹馍','凉皮','米线','米粉','螺蛳粉','酸辣粉','热干面','炸酱面','刀削面',
  '拉面','拌面','炒面','炒饭','盖浇饭','煲仔饭','卤肉饭','黄焖鸡','麻辣烫','冒菜','串串',
  '钵钵鸡','烧烤','烤肉','涮肉','火锅','干锅','铁板烧','寿司','刺身','天妇罗','部队锅',
  '石锅拌饭','咖喱饭','意面','汉堡','薯条','炸鸡','奶茶','果茶','拿铁','美式','摩卡',
  '卡布奇诺','蛋挞','舒芙蕾','慕斯','芝士','布丁','提拉米苏','预制菜','外卖','堂食',
  '打包','自助','招牌菜','私房菜','夜宵','早茶','下午茶','卤味','鸭脖','炸串','虾滑',
  '肥牛','毛肚','鸭血','牛油','麻辣锅','鸳鸯锅','小酥肉','糖葫芦','冰粉','双皮奶',
}
local n_food = 0
for _, w in ipairs(FOOD) do
  if add(w, '美食') then n_food = n_food + 1 end
end

-- ③ 体育：词表里几乎全是球队/球员名，改用精选术语
local SPORT = {
  '越位','点球','角球','任意球','边线球','界外球','开球','停球','传球','长传','短传',
  '直塞','盘带','运球','过人','射门','补射','抽射','推射','吊射','头球','乌龙球',
  '红牌','黄牌','加时赛','点球大战','半决赛','八强','四强','小组赛','淘汰赛','积分榜',
  '净胜球','主场','客场','联赛','杯赛','冠军','亚军','季军','教练','裁判','替补',
  '伤病','复出','转会','续约','三分球','罚球','篮板','助攻','抢断','盖帽','扣篮',
  '上篮','快攻','挡拆','跳投','扣杀','吊球','拉球','弧圈','直板','横板','跳发',
  '拦网','二传','主攻','自由人','中锋','边锋','前腰','后腰','边后卫','门将','扑救',
  '解围','传中','抢点','包抄','鱼跃','滑铲','铲球','头槌','三分线','禁区','越位线',
}
local n_sport = 0
for _, w in ipairs(SPORT) do
  if add(w, '体育') then n_sport = n_sport + 1 end
end

-- ④ 网络用语：词表是「表情动作描述」，质量差；改用常见新词清单（人工精选）
local NET = {
  '破防','内卷','躺平','摆烂','社死','上头','下头','真香','种草','拔草','剁手','吃土',
  '社恐','社牛','搭子','显眼包','松弛感','多巴胺','钝感力','智商税','割韭菜','情绪价值',
  '电子榨菜','新手保护期','雪王','浓人','淡人','村咖','来财','破圈','出圈','氛围感',
  '高级感','治愈系','小确幸','断舍离','沉浸式','碎片化','降维打击','闭环','赋能','抓手',
  '颗粒度','对齐','拉通','沉淀','落地','复盘','组合拳','性价比','平替','内耗','社畜',
  '打工人','干饭','干饭人','摸鱼','内推','上岸','卷王','凡尔赛','绝绝子','无语子',
  '冲鸭','鸭梨','离谱','绷不住','笑死','学到了','主理人','邪修','魔丸','灵珠',
  '赛博','对账','韧性','苏超','热梗','爆梗','出圈了','上分','开黑','掉线','连麦',
  '刷屏','秒回','已读','抱团','蹭热度','带节奏','洗地','反转','塌房','凉凉','搬砖',
}
local n_net = 0
for _, w in ipairs(NET) do
  if n_net >= 120 then break end
  if add(w, '网络') then n_net = n_net + 1 end
end

local f = assert(io.open(OUT, 'w'))
for _, line in ipairs(out) do f:write(line, '\n') end
f:close()

print(string.format('法律 %d / 美食 %d / 体育 %d / 网络 %d  合计 %d → %s',
  counts['法律'] or 0, counts['美食'] or 0, counts['体育'] or 0, counts['网络'] or 0, #out, OUT))
