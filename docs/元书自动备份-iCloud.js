// ============================================================
// 元书自动备份 - iCloud 版 (Scriptable)
// ============================================================
// 功能：每天定时把「我的 iPhone → 元书」方案目录（lua、码表、
//       predict.db、用户数据等）复制备份到
//       iCloud Drive/Scriptable/元书备份/<日期时间>/ 文件夹。
//
// 用法：
//   1. App Store 安装 Scriptable
//   2. 把本文件导入 Scriptable（AirDrop 或用「文件」App 打开）
//   3. 首次手动运行：选择「我的 iPhone → 元书」文件夹（只选一次，自动记住）
//   4. 快捷指令 App 新建快捷指令：
//      动作「运行 Scriptable 脚本」→ 选择「元书自动备份-iCloud」
//   5. 自动化：特定时间 23:00 每天 → 运行该快捷指令（关闭运行前询问）
//
// 说明：备份为文件级复制（不压缩），恢复时把备份文件夹内容整体
//       替换回「我的 iPhone → 元书」，再在元书中重新部署即可。
// ============================================================

const KEEP_BACKUPS = 30; // 保留最近 30 份，自动清理更旧的备份

// ---------- 工具函数 ----------
function joinPath(...parts) {
  return parts.join("/").replace(/\/+/g, "/");
}

function getFM() {
  try {
    const fm = FileManager.iCloud();
    fm.documentsDirectory(); // 验证可用
    return fm;
  } catch (e) {
    return FileManager.local();
  }
}

const FM = getFM();
const CONFIG_NAME = "元书备份配置.json";
const BACKUP_DIR = "元书备份"; // FM 根目录下（iCloud Drive/Scriptable/元书备份）

function configPath() {
  return joinPath(FM.documentsDirectory(), CONFIG_NAME);
}

function loadConfig() {
  const p = configPath();
  if (FM.fileExists(p)) {
    try {
      return JSON.parse(FM.readString(p));
    } catch (e) {
      return {};
    }
  }
  return {};
}

function saveConfig(cfg) {
  FM.writeString(configPath(), JSON.stringify(cfg));
}

function sourceAccessible(p) {
  if (!p) return false;
  try {
    return FM.fileExists(p) && FM.isDirectory(p);
  } catch (e) {
    return false;
  }
}

function getSource() {
  const cfg = loadConfig();
  if (sourceAccessible(cfg.sourcePath)) {
    return cfg.sourcePath;
  }
  // 首次运行：让用户选择「我的 iPhone → 元书」
  const picked = DocumentPicker.pickFolder("请选择「我的 iPhone → 元书」文件夹");
  if (!picked) {
    throw new Error("未选择源文件夹，已取消备份");
  }
  cfg.sourcePath = picked;
  saveConfig(cfg);
  return picked;
}

function copyRecursive(src, dst) {
  if (!FM.fileExists(dst)) {
    FM.createDirectory(dst, true);
  }
  const items = FM.listContents(src);
  for (const item of items) {
    const s = joinPath(src, item);
    const d = joinPath(dst, item);
    if (FM.isDirectory(s)) {
      copyRecursive(s, d);
    } else {
      FM.copyItem(s, d);
    }
  }
}

function dateStamp(d) {
  const pad = (n) => String(n).padStart(2, "0");
  return (
    d.getFullYear() +
    pad(d.getMonth() + 1) +
    pad(d.getDate()) +
    "-" +
    pad(d.getHours()) +
    pad(d.getMinutes())
  );
}

function cleanOldBackups(root) {
  try {
    const dirs = FM.listContents(root)
      .map((x) => joinPath(root, x))
      .filter((p) => {
        try {
          return FM.isDirectory(p);
        } catch (e) {
          return false;
        }
      });
    dirs.sort();
    while (dirs.length > KEEP_BACKUPS) {
      FM.removeItem(dirs.shift());
    }
  } catch (e) {
    // 清理失败不影响本次备份
  }
}

function notify(title, body) {
  const n = new Notification();
  n.title = title;
  n.body = body;
  n.sound = "default";
  n.schedule();
}

// ---------- 主流程 ----------
try {
  const src = getSource();
  const stamp = dateStamp(new Date());
  const root = joinPath(FM.documentsDirectory(), BACKUP_DIR);
  if (!FM.fileExists(root)) FM.createDirectory(root, true);
  const dest = joinPath(root, stamp);
  if (FM.fileExists(dest)) FM.removeItem(dest);
  FM.createDirectory(dest, true);
  copyRecursive(src, dest);
  cleanOldBackups(root);
  const files = FM.listContents(dest).length;
  notify("元书备份完成", `已备份到 ${BACKUP_DIR}/${stamp}（${files} 项）`);
  Script.setShortcutOutput(dest);
} catch (e) {
  const n = new Notification();
  n.title = "元书备份失败";
  n.body = String(e && e.message ? e.message : e);
  n.sound = "failure";
  n.schedule();
  throw e;
}