"""verify_package.py 的符号链接检查回归测试。

背景：tar 成员名带 `./` 前缀（`./a/x`），而 posixpath.normpath() 会把
`./a/.bin/x/../x` 规范化成 `a/x`（丢掉 `./`）。两边永远不相等，
结果**所有**符号链接都被判悬空 —— 曾经因此白烧两轮 CI。

这里用 tarfile.TarInfo 直接构造符号链接条目，
不依赖宿主能否创建真符号链接（Windows 非管理员做不到）。
"""
import os
import subprocess
import sys
import tarfile
import tempfile

VP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_package.py")
PY = sys.executable

if not os.path.exists(VP):
    print("✗ 找不到被测试的校验器: %s" % VP)
    sys.exit(2)

fails = []


def check(name, cond, detail=""):
    print(("  \u2713 " if cond else "  \u2717 ") + name + (("  " + detail) if detail else ""))
    if not cond:
        fails.append(name)


def make_tar(path, members):
    """members: (name, kind, payload)；kind in {'file','sym'}"""
    with tarfile.open(path, "w:gz") as tf:
        for name, kind, payload in members:
            ti = tarfile.TarInfo(name)
            if kind == "file":
                data = payload.encode()
                ti.size = len(data)
                ti.mode = 0o644
                tf.addfile(ti, __import__("io").BytesIO(data))
            else:
                ti.type = tarfile.SYMTYPE
                ti.linkname = payload
                ti.mode = 0o777
                tf.addfile(ti)


def run(tar_path):
    p = subprocess.run([PY, VP, tar_path], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


tmp = tempfile.mkdtemp(prefix="vp-")

# ---------- 情形 1：合法相对链接（应判「目标均存在」）----------
good = os.path.join(tmp, "good.tar.gz")
make_tar(good, [
    ("./a/x", "file", "payload"),
    ("./a/.bin/x", "sym", "../x"),
])
rc, out = run(good)
check("合法链接不被误判为悬空", "符号链接悬空" not in out)
check("合法链接判定通过", "符号链接目标均存在" in out,
      "" if "符号链接目标均存在" in out else "输出里没有该行")

# ---------- 情形 2：真悬空（必须被抓住）----------
bad_tar = os.path.join(tmp, "bad.tar.gz")
make_tar(bad_tar, [
    ("./a/x", "file", "payload"),
    ("./a/.bin/gone", "sym", "../gone/bin/gone"),
])
rc2, out2 = run(bad_tar)
check("真悬空会被抓住", "符号链接悬空" in out2)
check("真悬空时退出码非 0", rc2 != 0, "rc=%d" % rc2)

# ---------- 情形 3：绝对路径链接（必须被抓住）----------
abs_tar = os.path.join(tmp, "abs.tar.gz")
make_tar(abs_tar, [
    ("./a/x", "file", "payload"),
    ("./a/.bin/x", "sym", "/usr/bin/x"),
])
rc3, out3 = run(abs_tar)
check("绝对路径链接会被抓住", "符号链接必须相对" in out3)

print("\n== 结果: %s ==" % ("全部通过" if not fails else "%d 项失败" % len(fails)))
sys.exit(0 if not fails else 1)
