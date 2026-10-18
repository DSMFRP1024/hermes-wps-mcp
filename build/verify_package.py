"""离线包产物校验 —— 流式读 tar，不解包。

CI 打完包后立刻跑，本地下载回来再跑同一份规则。
拦的是「打包成功但内容不对」：漏了入口、混进 dev 依赖、混进源码、清单与实际不符。

用法：python3 build/verify_package.py dist-pkg/wps-mcp-offline-aarch64.tar.gz
"""
import json
import os
import posixpath
import re
import sys
import tarfile

pass_n = 0
fail_n = 0
problems = []


def ok(name, extra=""):
    global pass_n
    pass_n += 1
    print("  \u2713 %s%s" % (name, ("  " + extra) if extra else ""))


def bad(name, detail):
    global fail_n
    fail_n += 1
    problems.append("%s: %s" % (name, detail))
    print("  \u2717 %s  %s" % (name, detail))


MUST_HAVE = [
    "./install.sh",
    "./wps-office-mcp/dist/index.js",
    "./wps-office-mcp/dist/client/mac-poll-server.js",
    "./wps-office-mcp/dist/client/wps-client.js",
    "./wps-office-mcp/dist/server/mcp-server.js",
    "./wps-office-mcp/node_modules/@modelcontextprotocol/sdk/package.json",
    "./wps-office-mcp/package.json",
    "./wps-claude-assistant/manifest.xml",
    "./wps-claude-assistant/ribbon.xml",
    "./wps-claude-assistant/main.js",
    "./build-info.json",
    "./MANIFEST.tsv",
    "./MANIFEST.links.tsv",
]

MUST_NOT_HAVE_PREFIX = [
    # 明确不该进来的：构建/测试工具链
    "./wps-office-mcp/node_modules/jest/",
    "./wps-office-mcp/node_modules/ts-jest/",
    "./wps-office-mcp/node_modules/typescript/",
    "./wps-office-mcp/node_modules/ts-node/",
    "./wps-office-mcp/node_modules/rimraf/",
    # 缓存与临时物
    "./wps-office-mcp/node_modules/.cache/",
    "./.git/",
    "./.stage/",
]

# 注意：不能笼统禁掉 node_modules/@types/。
# @types/triple-beam 是 logform（winston 的依赖）的**生产依赖**，
# 按前缀禁会把合法内容判成违规。dev 依赖改为按 package.json 的
# devDependencies 逐个核对（见 [3b]）。


def main():
    if len(sys.argv) < 2:
        print("用法: python3 build/verify_package.py <tarball>")
        return 2
    tb = sys.argv[1]
    if not os.path.exists(tb):
        print("✗ 文件不存在: %s" % tb)
        return 1

    print("== 离线包校验 ==")
    print("   %s (%d B / %.2f MiB)\n" % (tb, os.path.getsize(tb),
                                         os.path.getsize(tb) / 1048576))

    members = []
    try:
        with tarfile.open(tb, "r:gz") as tf:
            for m in tf:
                members.append(m)
    except Exception as e:
        print("✗ 无法读取 tar: %s: %s" % (type(e).__name__, e))
        return 1

    names = [m.name for m in members]
    files = [m for m in members if m.isfile()]
    links = [m for m in members if m.issym()]

    print("[1] 结构")
    ok("条目统计", "%d 个条目（文件 %d / 符号链接 %d）" % (len(members), len(files), len(links)))
    if len(files) < 100:
        bad("文件数", "仅 %d 个，包可能不完整" % len(files))

    print("\n[2] 必需文件")
    nameset = set(names)
    # tar 里目录条目可能带/不带尾部斜杠，统一按前缀匹配
    for req in MUST_HAVE:
        if req in nameset:
            ok(req)
        else:
            hit = [n for n in names if n.rstrip("/") == req.rstrip("/")]
            if hit:
                ok(req, "(路径形态 %s)" % hit[0])
            else:
                bad(req, "缺失")

    print("\n[3] 不该出现的内容")
    for pref in MUST_NOT_HAVE_PREFIX:
        hit = [n for n in names if n.startswith(pref)]
        if hit:
            bad("不应包含 %s" % pref, "%d 个条目，例如 %s" % (len(hit), hit[0]))
        else:
            ok("无 %s" % pref)

    print("\n[3b] devDependencies 逐个核对")
    # 按包内 package.json 逐条断言，比「按前缀猜」准确：
    # 既不放过真进来的 dev 依赖，也不误伤被生产依赖引用的 @types。
    pkg_name = next((n for n in names if n.rstrip("/") == "./wps-office-mcp/package.json"), None)
    if not pkg_name:
        bad("wps-office-mcp/package.json", "缺失，无法核对 dev 依赖")
    else:
        try:
            with tarfile.open(tb, "r:gz") as tf:
                meta = json.loads(tf.extractfile(pkg_name).read().decode("utf-8"))
            devdeps = sorted(meta.get("devDependencies") or {})
            if not devdeps:
                ok("package.json 未声明 devDependencies")
            leaked = []
            for d in devdeps:
                pref = "./wps-office-mcp/node_modules/%s/" % d
                hit = [n for n in names if n == pref.rstrip("/") or n.startswith(pref)]
                if hit:
                    leaked.append((d, hit[0]))
            if leaked:
                bad("混入 dev 依赖",
                    "%d 个: %s" % (len(leaked), ", ".join(d for d, _ in leaked)))
            else:
                ok("dev 依赖均已排除", "%d 个: %s" % (len(devdeps), " ".join(devdeps)))
        except Exception as e:
            bad("package.json 解析", "%s: %s" % (type(e).__name__, e))

    print("\n[4] 源码泄漏")
    # 只查我们自己的产物与源码树。第三方包自带 .ts 是正常的
    # （例如 ajv 就把 lib/*.ts 一起发布），不能算泄漏。
    ours = ("./wps-office-mcp/dist/", "./wps-office-mcp/src/")
    stray = [n for n in names
             if n.startswith(ours)
             and re.search(r"\.(ts|tsx)$", n) and not n.endswith(".d.ts")]
    if stray:
        bad("自有产物不应含 .ts", "%d 个，例如 %s" % (len(stray), stray[0]))
    else:
        ok("自有产物无 .ts 源码")

    print("\n[5] 符号链接安全性")
    dangling = []
    relative_bad = []
    for m in links:
        if os.path.isabs(m.linkname):
            relative_bad.append("%s -> %s" % (m.name, m.linkname))
            continue
        target = posixpath.normpath(posixpath.join(posixpath.dirname(m.name), m.linkname))
        if target not in nameset and not any(n.startswith(target + "/") for n in names):
            dangling.append("%s -> %s (=%s)" % (m.name, m.linkname, target))
    if relative_bad:
        bad("符号链接必须相对", "%d 个绝对指向，例如 %s" % (len(relative_bad), relative_bad[0]))
    else:
        ok("符号链接均为相对路径")
    if dangling:
        bad("符号链接悬空", "%d 个，例如 %s" % (len(dangling), dangling[0]))
    else:
        ok("符号链接目标均存在")

    print("\n[6] MANIFEST 一致性")
    man_name = next((n for n in names if n.rstrip("/") == "./MANIFEST.tsv"), None)
    if not man_name:
        bad("MANIFEST.tsv", "缺失")
    else:
        try:
            with tarfile.open(tb, "r:gz") as tf:
                fh = tf.extractfile(man_name)
                text = fh.read().decode("utf-8", "replace")
            listed = set()
            for line in text.splitlines():
                if not line.strip():
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2:
                    continue
                listed.add(parts[1].strip())
            actual = set(m.name for m in files)
            # MANIFEST 自身在生成后才写，允许它不在清单里
            missing = actual - listed - {"./MANIFEST.tsv"}
            extra = listed - actual
            if missing:
                bad("清单漏登记", "%d 个，例如 %s" % (len(missing), sorted(missing)[0]))
            else:
                ok("清单覆盖全部普通文件", "%d 条" % len(listed))
            if extra:
                bad("清单登记了不存在的文件", "%d 个，例如 %s" % (len(extra), sorted(extra)[0]))
        except Exception as e:
            bad("MANIFEST 解析", "%s: %s" % (type(e).__name__, e))

    print("\n[7] build-info")
    bi = next((n for n in names if n.rstrip("/") == "./build-info.json"), None)
    if bi:
        try:
            with tarfile.open(tb, "r:gz") as tf:
                info = json.loads(tf.extractfile(bi).read().decode("utf-8"))
            ok("build-info 可解析", json.dumps(info, ensure_ascii=False)[:120])
            for k in ("arch", "git_sha", "node"):
                if k not in info:
                    bad("build-info 缺字段", k)
        except Exception as e:
            bad("build-info 解析", str(e))
    else:
        bad("build-info.json", "缺失")

    print("\n== 结果: %d 通过 / %d 失败 ==" % (pass_n, fail_n))
    if fail_n:
        print("\n问题项：")
        for p in problems:
            print("  - " + p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
