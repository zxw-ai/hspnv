// ============================================================
// 元书自动备份 - WebDAV 版 (Scriptable)
// ============================================================
// 功能：每天定时把「我的 iPhone → 元书」方案目录上传到
//       WebDAV 服务器（坚果云 / Nextcloud / 群晖 NAS / 自建）。
//       远程目录：<WebDAV地址>/<日期时间>/
//
// 用法：
//   1. App Store 安装 Scriptable，导入本文件
//   2. 首次手动运行：
//      a. 输入 WebDAV 地址、用户名、应用密码（自动保存）
//      b. 选择「我的 iPhone → 元书」文件夹（只选一次）
//   3. 快捷指令 App：
//      动作「运行 Scriptable 脚本」→ 选择「元书自动备份-WebDAV」
//   4. 自动化：特定时间 23:00 每天 → 运行该快捷指令（关闭运行前询问）
//
// 注意：WebDAV 地址应包含备份目录，例如
//       https://dav.jianguoyun.com/dav/元书备份
//       请先在 WebDAV 中创建该目录（坚果云需用「应用密码」）。
// ============================================================

const CONFIG_NAME = "元书WebDAV配置.json";

// ---------- 工具函数 ----------
function joinPath(...parts) {
  return parts.join("/").replace(/\/+/g, "/");
}

function getFM() {
  try {
    const fm = FileManager.iCloud();
    fm.documentsDirectory();
    return fm;
  } catch (e) {
    return FileManager.local();
  }
}

const FM = getFM();

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

async function getConfig() {
  let cfg = loadConfig();
  if (
    cfg.webdavURL &&
    cfg.username &&
    cfg.password &&
    sourceAccessible(cfg.sourcePath)
  ) {
    return cfg;
  }
  // 首次配置：输入 WebDAV 信息
  const alert = new Alert();
  alert.title = "WebDAV 备份配置";
  alert.message =
    "填写 WebDAV 地址、用户名、应用密码，然后选择「我的 iPhone → 元书」文件夹。";
  alert.addTextField(
    "WebDAV 地址（含备份目录）",
    cfg.webdavURL || "https://dav.jianguoyun.com/dav/元书备份"
  );
  alert.addTextField("用户名", cfg.username || "");
  alert.addTextField("应用密码", cfg.password || "");
  alert.addAction("下一步");
  alert.addCancelAction("取消");
  const idx = await alert.present();
  if (idx !== 0) throw new Error("已取消配置");
  cfg.webdavURL = alert.textFieldValue(0).trim().replace(/\/+$/, "");
  cfg.username = alert.textFieldValue(1).trim();
  cfg.password = alert.textFieldValue(2).trim();
  if (!cfg.webdavURL || !cfg.username || !cfg.password) {
    throw new Error("WebDAV 配置不完整");
  }
  const picked = DocumentPicker.pickFolder("请选择「我的 iPhone → 元书」文件夹");
  if (!picked) throw new Error("未选择源文件夹");
  cfg.sourcePath = picked;
  saveConfig(cfg);
  return cfg;
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

async function webdavMkcol(url, auth) {
  const req = new Request(url);
  req.method = "MKCOL";
  req.headers = { Authorization: "Basic " + auth };
  try {
    await req.load();
  } catch (e) {
    // 目录已存在（405/301）或网络错误都忽略，PUT 阶段会暴露真实问题
  }
}

async function webdavPut(url, auth, data) {
  const req = new Request(url);
  req.method = "PUT";
  req.headers = {
    Authorization: "Basic " + auth,
    "Content-Type": "application/octet-stream",
  };
  req.body = data;
  await req.load();
  if (req.response && req.response.statusCode >= 400) {
    throw new Error("上传失败 HTTP " + req.response.statusCode + ": " + url);
  }
}

async function uploadRecursive(fm, localDir, remoteDir, auth) {
  const items = fm.listContents(localDir);
  for (const item of items) {
    const l = joinPath(localDir, item);
    const r = remoteDir + "/" + encodeURIComponent(item);
    if (fm.isDirectory(l)) {
      await webdavMkcol(encodeURI(r), auth);
      await uploadRecursive(fm, l, r, auth);
    } else {
      const data = fm.read(l);
      await webdavPut(encodeURI(r), auth, data);
    }
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
async function main() {
  const cfg = await getConfig();
  const auth = Data.fromString(cfg.username + ":" + cfg.password).toBase64String();
  const stamp = dateStamp(new Date());
  const remoteDir = cfg.webdavURL + "/" + stamp;
  await webdavMkcol(encodeURI(remoteDir), auth);
  await uploadRecursive(FM, cfg.sourcePath, remoteDir, auth);
  notify("元书备份完成", "已上传到 WebDAV/" + stamp);
  Script.setShortcutOutput(remoteDir);
}

main().catch((e) => {
  const n = new Notification();
  n.title = "元书备份失败";
  n.body = String(e && e.message ? e.message : e);
  n.sound = "failure";
  n.schedule();
  throw e;
});