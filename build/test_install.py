"""install.sh 的集成测试 —— 重点验证「不破坏目标机已有配置」。

CI 里可以直接跑（无 WPS、无图形会话也能过），因为它只测安装语义：
  1. 预置一个「别人的」加载项
  2. 安装 -> 新增 claude-assistant，other-vendor 仍在（不许覆盖）
  3. 再装一次 -> 幂等，条目不重复，旧目录被备份而非覆盖
  4. 卸载 -> 移除 claude-assistant，other-vendor 仍在

用法：python3 build/test_install.py
      WPS_TEST_BASH=/path/to/bash python3 build/test_install.py   # 指定 shell
"""
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASH = os.environ.get("WPS_TEST_BASH", "bash")

# 真包带 node_modules（4748 个文件），Windows 上复制一次要几分钟；
# install.sh 的校验段只判断文件是否存在，所以本地调试可用桩包：
#   WPS_TEST_STUB=1 python3 build/test_install.py
# CI 里不要设它 —— 必须用真包跑。
STUB = os.environ.get("WPS_TEST_STUB") == "1"

STUB_FILES = [
    "wps-office-mcp/dist/index.js",
    "wps-office-mcp/node_modules/@modelcontextprotocol/sdk/package.json",
    "wps-claude-assistant/manifest.xml",
    "wps-claude-assistant/ribbon.xml",
    "wps-claude-assistant/main.js",
]

SEED = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<jsplugins>
  <jsplugin name="other-vendor" type="et" url="other_/" enable="enable_dev"/>
</jsplugins>
"""

fails = []


def check(name, cond, detail=""):
    if cond:
        print("  \u2713 %s%s" % (name, ("  " + detail) if detail else ""))
    else:
        print("  \u2717 %s  %s" % (name, detail))
        fails.append(name)


def clean(path):
    """删目录。避开本机被劫持的 os.remove —— 逐个删并兜住异常。"""
    if not os.path.isdir(path):
        return
    for root, dirs, files in os.walk(path, topdown=False):
        for f in files:
            try:
                os.remove(os.path.join(root, f))
            except OSError:
                pass
        for d in dirs:
            try:
                os.rmdir(os.path.join(root, d))
            except OSError:
                pass
    try:
        os.rmdir(path)
    except OSError:
        pass


def make_stub_pkg(root):
    """在 root 下造一个「只有文件形状」的包，用于快速验证安装语义。"""
    pkg = os.path.join(root, "pkg")
    for rel in STUB_FILES:
        p = os.path.join(pkg, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write("stub\n")
    with open(os.path.join(PKG, "install.sh"), "rb") as a, \
            open(os.path.join(pkg, "install.sh"), "wb") as b:
        b.write(a.read())
    return pkg


def main():
    global PKG
    tmp = tempfile.mkdtemp(prefix="wpsinstall-")
    if STUB:
        PKG = make_stub_pkg(tmp)
        print("== 桩包模式（WPS_TEST_STUB=1）：跳过 node_modules 复制 ==")
    prefix = os.path.join(tmp, "prefix")
    jsd = os.path.join(tmp, "jsaddons")
    pub = os.path.join(jsd, "publish.xml")

    def run_install(*extra):
        cmd = [BASH, os.path.join(PKG, "install.sh"),
               "--prefix", prefix, "--jaddons", jsd, *extra]
        p = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=900)
        return p.returncode, (p.stdout or "") + (p.stderr or "")

    def plugins():
        if not os.path.exists(pub):
            return []
        return [(n.get("name"), n.get("type"), n.get("url"), n.get("enable"))
                for n in ET.parse(pub).getroot()]

    print("== 准备：预置一个别的加载项 ==")
    os.makedirs(jsd, exist_ok=True)
    with open(pub, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(SEED)
    print("   publish.xml: %s" % plugins())

    # ---------------- 第 1 次安装 ----------------
    print("\n== 第 1 次安装 ==")
    rc, out = run_install()
    check("退出码 0", rc == 0, "rc=%d" % rc)
    if rc != 0:
        print(out[-2000:])
        return 1

    ps = plugins()
    print("   publish.xml: %s" % ps)
    names = [p[0] for p in ps]
    check("新增 claude-assistant", "claude-assistant" in names)
    check("未破坏 other-vendor", "other-vendor" in names, "红线：不许覆盖已有配置")

    ca = next((p for p in ps if p[0] == "claude-assistant"), None)
    check("type = wps,et,wpp", ca and ca[1] == "wps,et,wpp", str(ca))
    check("url = claude-assistant_/", ca and ca[2] == "claude-assistant_/", str(ca))
    check("enable = enable_dev", ca and ca[3] == "enable_dev", str(ca))

    addon_dir = os.path.join(jsd, "claude-assistant_")
    check("加载项目录已部署", os.path.isdir(addon_dir))
    check("含 manifest.xml", os.path.isfile(os.path.join(addon_dir, "manifest.xml")))
    check("含 main.js", os.path.isfile(os.path.join(addon_dir, "main.js")))
    check("服务入口已部署",
          os.path.isfile(os.path.join(prefix, "wps-office-mcp", "dist", "index.js")))
    # mac-poll-server.ts 里 switchApp 用 ../../../wps-claude-assistant 定位脚本，
    # 所以两者必须同级
    check("服务与加载项同级（路径依赖）",
          os.path.isdir(os.path.join(prefix, "wps-claude-assistant")))

    raw = open(pub, encoding="utf-8").read()
    check("声明双引号 + standalone",
          raw.startswith('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'),
          raw.splitlines()[0] if raw else "")
    check("无 BOM", not raw.startswith("\ufeff"))

    # ---------------- 第 2 次安装（幂等） ----------------
    print("\n== 第 2 次安装（幂等） ==")
    before = set(os.listdir(jsd))
    rc, out = run_install()
    check("退出码 0", rc == 0, "rc=%d" % rc)
    ps2 = plugins()
    names2 = [p[0] for p in ps2]
    check("条目数仍为 2", len(ps2) == 2, str(names2))
    check("claude-assistant 未重复", names2.count("claude-assistant") == 1)
    check("other-vendor 仍在", "other-vendor" in names2)
    newdirs = [d for d in os.listdir(jsd) if d not in before]
    check("旧目录被备份而非覆盖",
          any(".bak." in d for d in newdirs), str(newdirs))

    # ---------------- 卸载 ----------------
    print("\n== 卸载 ==")
    rc, out = run_install("--uninstall")
    check("退出码 0", rc == 0, "rc=%d" % rc)
    ps3 = plugins()
    names3 = [p[0] for p in ps3]
    print("   publish.xml: %s" % ps3)
    check("claude-assistant 已移除", "claude-assistant" not in names3)
    check("other-vendor 仍在", "other-vendor" in names3, "红线：卸载不许误伤")
    check("安装目录移到备份（未删除）",
          not os.path.isdir(prefix)
          and any(".bak." in d for d in os.listdir(tmp)),
          str(os.listdir(tmp)))
    check("加载项目录已移除",
          not os.path.isdir(addon_dir))

    print("\n== 结果: %s ==" % ("全部通过" if not fails
                                else "%d 项失败" % len(fails)))
    if fails:
        for f in fails:
            print("  - " + f)

    # 清理（失败也清，避免 CI 磁盘堆积）
    clean(tmp)
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
