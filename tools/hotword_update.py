#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hotword_update.py — hspnv 笔画方案热词自动更新工具（路线 F）

借鉴讯飞 hotword.dat 热词机制：定期把网络热词/用户热词转成笔画码写入词库，
并记录插入时间，支持过期自动降权移除，让词库"保鲜"。

用法：
  python3 hotword_update.py hotwords.txt [--weight 1001] [--expire-days 90] [--dry-run]
  python3 hotword_update.py --backup --user-dir <元书用户目录>   # 仅备份用户词库
  python3 hotword_update.py hotwords.txt --blacklist my_blacklist.txt

热词文件格式（每行一个词，可选制表符权重）：
  显眼包
  配得感        1501
  # 以 # 开头的行是注释

行为：
  1. 从 stroke_hspnv.dict.yaml 加载单字码表，逐字拼接生成整词笔画码；
  2. 跳过含英文/数字/生僻字（码表查不到）的词；
  3. 已存在于 words.lua / dict.yaml / 日志的词自动跳过；
  4. 【黑名单】tools/blacklist.txt 中的词跳过（对标讯飞热词黑名单 notifyBlackHotWord）；
  5. 新词写入 words.lua（权重 1001 或自定义）并追加到 dict.yaml；
  6. 记录 tools/hotword_log.tsv（词、码、日期、权重）；
  7. --expire-days N：超过 N 天未更新的词自动从词库移除（过期降权）；
  8. --backup：把用户目录的学习/ngram/降权数据备份到 tools/backup/。

注意：运行后需重新部署方案（元书）才会生效。
"""

import os
import re
import sys
import shutil
import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_DIR = os.path.dirname(HERE)
WORDS_LUA = os.path.join(SCHEMA_DIR, "lua", "words.lua")
DICT_YAML = os.path.join(SCHEMA_DIR, "stroke_hspnv.dict.yaml")
LOG_TSV = os.path.join(HERE, "hotword_log.tsv")
BACKUP_DIR = os.path.join(HERE, "backup")
BLACKLIST_PATH = os.path.join(HERE, "blacklist.txt")
DEFAULT_WEIGHT = 1001

# 用户目录下的个人数据文件（对标讯飞云备份：learning/ngram/demote）
USER_DATA_FILES = [
    "bg5-learning.user.tsv",
    "bg5-ngram.user.tsv",
    "demote.user.tsv",
]

# ---------- 工具 ----------
def utf8_chars(s):
    """按字符切分 UTF-8 字符串（含中文）。"""
    return list(s)  # Python str 已按码点迭代

def is_chinese_char(ch):
    return len(ch.encode("utf-8")) == 3 and '\u4e00' <= ch <= '\u9fff'

def load_blacklist(path):
    """加载黑名单（每行一词，# 开头为注释）。不存在则返回空集合。"""
    words = set()
    if not path or not os.path.exists(path):
        return words
    with open(path, encoding="utf-8") as f:
        for line in f:
            w = line.strip()
            if w and not w.startswith("#"):
                words.add(w)
    return words

def backup_user_data(user_dir):
    """备份用户目录下的个人数据文件到 tools/backup/（带时间戳）。返回备份文件数。"""
    if not user_dir or not os.path.isdir(user_dir):
        print(f"[错误] 用户目录不存在: {user_dir}")
        return 0
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    count = 0
    for name in USER_DATA_FILES:
        src = os.path.join(user_dir, name)
        if os.path.exists(src):
            dst = os.path.join(BACKUP_DIR, name + "." + stamp)
            shutil.copy2(src, dst)
            print(f"  [备份] {name} -> {dst}")
            count += 1
    return count

def load_char_codes():
    """从 dict.yaml 加载单字码表：字 -> 笔画码（仅取词长为 1 的行）。"""
    codes = {}
    with open(DICT_YAML, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("---") or line.startswith("..."):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                word = parts[0]
                if len(word) == 1 and is_chinese_char(word):
                    codes[word] = parts[1]
    return codes

def word_to_stroke(word, codes):
    """整词转笔画码；任一字符非汉字或查不到码则返回 None。"""
    out = []
    for ch in word:
        if not is_chinese_char(ch):
            return None
        code = codes.get(ch)
        if not code:
            return None
        out.append(code)
    return "".join(out)

def load_words_lua_set():
    """从 words.lua 提取已有词条集合。"""
    words = set()
    pat = re.compile(r'^\s*\["([^"]+)"\]\s*=')
    with open(WORDS_LUA, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line)
            if m:
                words.add(m.group(1))
    return words

def load_dict_set():
    """从 dict.yaml 提取已有词条集合（首列）。"""
    words = set()
    with open(DICT_YAML, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("---") or line.startswith("..."):
                continue
            word = line.split("\t", 1)[0]
            if word:
                words.add(word)
    return words

def load_log():
    """日志：词 -> (码, 日期, 权重)。"""
    log = {}
    if os.path.exists(LOG_TSV):
        with open(LOG_TSV, encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    log[parts[0]] = (parts[1], parts[2], parts[3] if len(parts) > 3 else str(DEFAULT_WEIGHT))
    return log

def save_log(log):
    tmp = LOG_TSV + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for w, (code, date, weight) in log.items():
            f.write(f"{w}\t{code}\t{date}\t{weight}\n")
    os.replace(tmp, LOG_TSV)

def backup():
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    for src in (WORDS_LUA, DICT_YAML):
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(BACKUP_DIR, os.path.basename(src) + "." + stamp))

# ---------- 插入 ----------
def insert_words(words_lua_set, dict_set, new_items):
    """new_items: [(词, 码, 权重)]。返回实际新增的 (词, 码, 权重) 列表。"""
    added = []
    for w, code, weight in new_items:
        if w in words_lua_set and w in dict_set:
            continue
        added.append((w, code, weight))
    if not added:
        return added

    backup()

    # words.lua：在 return { 后插入新行
    with open(WORDS_LUA, encoding="utf-8") as f:
        content = f.read()
    lines = content.split("\n")
    insert_at = None
    for i, line in enumerate(lines):
        if line.strip() == "return {":
            insert_at = i + 1
            break
    if insert_at is None:
        raise RuntimeError("words.lua 未找到 'return {'")
    new_lines = []
    for w, code, weight in added:
        new_lines.append(f'  ["{w}"]={weight},')
    lines[insert_at:insert_at] = new_lines
    tmp = WORDS_LUA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp, WORDS_LUA)

    # dict.yaml：末尾追加
    with open(DICT_YAML, "a", encoding="utf-8") as f:
        for w, code, weight in added:
            f.write(f"{w}\t{code}\t{weight}\n")

    return added

# ---------- 过期移除 ----------
def remove_expired(log, expire_days):
    """移除超过 expire_days 的词条。返回移除的 (词, 码)。"""
    today = datetime.date.today()
    cutoff = today - datetime.timedelta(days=expire_days)
    expired = []
    for w, (code, date, weight) in log.items():
        try:
            d = datetime.date.fromisoformat(date)
        except ValueError:
            continue
        if d < cutoff:
            expired.append((w, code))
    if not expired:
        return expired

    backup()
    expired_set = {w for w, _ in expired}

    # words.lua 删除对应行
    with open(WORDS_LUA, encoding="utf-8") as f:
        lines = f.readlines()
    pat = re.compile(r'^\s*\["([^"]+)"\]\s*=')
    new_lines = []
    for line in lines:
        m = pat.match(line)
        if m and m.group(1) in expired_set:
            continue
        new_lines.append(line)
    if len(new_lines) != len(lines):
        tmp = WORDS_LUA + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
        os.replace(tmp, WORDS_LUA)

    # dict.yaml 删除对应行（按首列词匹配）
    with open(DICT_YAML, encoding="utf-8") as f:
        lines = f.readlines()
    new_lines = []
    for line in lines:
        word = line.split("\t", 1)[0]
        if word in expired_set:
            continue
        new_lines.append(line)
    if len(new_lines) != len(lines):
        tmp = DICT_YAML + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(new_lines)
        os.replace(tmp, DICT_YAML)

    return expired

# ---------- 主流程 ----------
def main():
    import argparse
    parser = argparse.ArgumentParser(description="hspnv 热词更新")
    parser.add_argument("hotwords", nargs="?", help="热词文件（每行一词，可 词\\t权重）")
    parser.add_argument("--weight", type=int, default=DEFAULT_WEIGHT, help="新词权重")
    parser.add_argument("--expire-days", type=int, default=0, help="超过 N 天的热词自动移除（0=不移除）")
    parser.add_argument("--dry-run", action="store_true", help="只预览不写入")
    parser.add_argument("--blacklist", default=BLACKLIST_PATH, help="黑名单文件（默认 tools/blacklist.txt）")
    parser.add_argument("--backup", action="store_true", help="备份用户词库数据到 tools/backup/")
    parser.add_argument("--user-dir", help="元书用户数据目录（用于 --backup）")
    args = parser.parse_args()

    # 用户词库备份（对标讯飞云备份）
    if args.backup:
        n = backup_user_data(args.user_dir)
        print(f"[备份] 完成，共 {n} 个文件。备份目录：{BACKUP_DIR}")
        if not args.hotwords:
            return

    log = load_log()

    # 过期移除
    if args.expire_days > 0:
        expired = remove_expired(log, args.expire_days)
        print(f"[移除] {len(expired)} 个过期热词")
        for w, code in expired:
            print(f"  - {w}\t{code}")
            log.pop(w, None)
        save_log(log)

    # 无热词文件时结束
    if not args.hotwords:
        print("[完成] 无热词文件，仅执行过期移除。")
        return
    if not os.path.exists(args.hotwords):
        print(f"[错误] 文件不存在: {args.hotwords}")
        sys.exit(1)

    codes = load_char_codes()
    words_lua_set = load_words_lua_set()
    dict_set = load_dict_set()
    blacklist = load_blacklist(args.blacklist)
    today = datetime.date.today().isoformat()

    new_items = []
    skipped = []
    seen_new = set()
    with open(args.hotwords, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw or raw.startswith("#"):
                continue
            parts = raw.split("\t")
            w = parts[0]
            weight = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else args.weight
            if w in blacklist:
                skipped.append((w, "黑名单"))
                continue
            if w in log:
                skipped.append((w, "已在日志中"))
                continue
            if w in seen_new:
                skipped.append((w, "文件内重复"))
                continue
            if not all(is_chinese_char(ch) for ch in w):
                skipped.append((w, "含非汉字"))
                continue
            code = word_to_stroke(w, codes)
            if not code:
                skipped.append((w, "码表查不到"))
                continue
            if w in words_lua_set and w in dict_set:
                skipped.append((w, "词库已存在"))
                continue
            seen_new.add(w)
            new_items.append((w, code, weight))

    print(f"[读取] 码表字 {len(codes)} 个；待插入 {len(new_items)}，跳过 {len(skipped)}")
    for w, reason in skipped:
        print(f"  跳过 {w}（{reason}）")

    if args.dry_run:
        for w, code, weight in new_items:
            print(f"  [预览] {w}\t{code}\t{weight}")
        return

    added = insert_words(words_lua_set, dict_set, new_items)
    for w, code, weight in added:
        log[w] = (code, today, str(weight))
        print(f"  [插入] {w}\t{code}\t{weight}")
    save_log(log)
    print(f"[完成] 新增 {len(added)} 词。日志 {len(log)} 条。")
    print("注意：请重新部署方案（元书）后生效。")

if __name__ == "__main__":
    main()