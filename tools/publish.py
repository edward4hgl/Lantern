"""把灯箱项目推到 GitHub：建仓库 + 逐文件上传，不建 release，不含任何构建产物。

用法:
    python tools/publish.py                # 从环境变量 GITHUB_TOKEN 取 token，没有就交互式问
    python tools/publish.py --private
    python tools/publish.py --dry-run      # 只列出会上传的文件

只用标准库，不需要 git、不需要 GitHub CLI。
可重复跑：内容没变的会跳过，变了的会更新，本地已删掉的会从仓库里清掉。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
ROOT = pathlib.Path(__file__).resolve().parent.parent

DESCRIPTION = "灯箱 Lantern · 把你的共享相簿变成一面自己会换照片的墙（iPadOS · SwiftUI）"

SKIP_DIRS = {
    ".git", "build", "build-sim", "build-device", "DerivedData", "out",
    "__pycache__", ".vscode", ".build", "node_modules",
}
SKIP_SUFFIX = {
    ".ipa", ".p12", ".mobileprovision", ".keychain-db",
    ".xcuserstate", ".o", ".swiftmodule", ".a", ".dylib", ".ini", ".log",
}
SKIP_EXACT = {".DS_Store", "Thumbs.db", "tools/_scrub.py", "tools/_ghstatus.py"}
MAX_BYTES = 20 * 1024 * 1024
RETRIES = 4


def collect() -> list[tuple[str, pathlib.Path]]:
    files: list[tuple[str, pathlib.Path]] = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        if set(path.relative_to(ROOT).parts) & SKIP_DIRS:
            continue
        if ".xcodeproj" in rel or ".xcworkspace" in rel or ".dSYM" in rel:
            continue
        if path.suffix.lower() in SKIP_SUFFIX or rel in SKIP_EXACT:
            continue
        if path.stat().st_size > MAX_BYTES:
            print(f"  skip (too big): {rel}", file=sys.stderr)
            continue
        files.append((rel, path))
    return files


def request(token: str, method: str, path: str, payload: dict | None = None) -> tuple[int, dict]:
    """带重试的 GitHub 调用。4xx 视为确定结果，5xx / 网络错误重试。"""
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode() if payload is not None else None
    last: tuple[int, dict] = (0, {})
    for attempt in range(RETRIES):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "lantern-publish")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                body = resp.read().decode("utf-8", "replace")
                return resp.status, (json.loads(body) if body.strip() else {})
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = {"message": body[:400]}
            if exc.code < 500 and exc.code != 429:
                return exc.code, parsed
            last = (exc.code, parsed)
        except Exception as exc:                 # SSL EOF / 超时 / 连接重置
            last = (0, {"message": f"{type(exc).__name__}: {exc}"})
        time.sleep(1.5 * (attempt + 1))
    return last


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    parser.add_argument("--repo", default="Lantern")
    parser.add_argument("--private", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    files = collect()
    print(f"待上传 {len(files)} 个文件")
    if args.dry_run:
        for rel, path in files:
            print(f"  {path.stat().st_size:>8,}  {rel}")
        return 0

    token = args.token
    if not token:
        import getpass
        token = getpass.getpass("粘贴 GitHub token（输入不回显）: ").strip()
    if not token:
        print("没有拿到 token", file=sys.stderr)
        return 2

    status, me = request(token, "GET", "/user")
    if status != 200:
        print(f"token 无效：{status} {me.get('message')}", file=sys.stderr)
        return 3
    owner = me["login"]
    print(f"登录为 {owner}")

    status, repo = request(token, "POST", "/user/repos", {
        "name": args.repo,
        "description": DESCRIPTION,
        "private": args.private,
        "has_issues": True,
        "has_wiki": False,
        "has_projects": False,
        "auto_init": True,
    })
    if status == 201:
        print(f"已创建 {repo['full_name']}")
    elif status == 422:
        status, repo = request(token, "GET", f"/repos/{owner}/{args.repo}")
        if status != 200:
            print(f"读不到仓库：{status} {repo.get('message')}", file=sys.stderr)
            return 4
        print(f"仓库已存在：{repo['html_url']}")
    else:
        print(f"建仓库失败：{status} {repo}", file=sys.stderr)
        return 5

    branch = repo.get("default_branch") or "main"
    base = f"/repos/{owner}/{args.repo}"
    ok = 0
    deferred: list[tuple[str, pathlib.Path, str]] = []

    for rel, path in files:
        quoted = urllib.parse.quote(rel)
        status, existing = request(token, "GET", f"{base}/contents/{quoted}?ref={branch}")
        remote_sha = existing.get("sha") if status == 200 and isinstance(existing, dict) else None
        payload: dict = {
            "message": f"update {rel}" if remote_sha else f"add {rel}",
            "content": base64.b64encode(path.read_bytes()).decode(),
            "branch": branch,
        }
        if remote_sha:
            payload["sha"] = remote_sha
        status, body = request(token, "PUT", f"{base}/contents/{quoted}", payload)
        if status in (200, 201):
            ok += 1
            print(f"  ok  {rel}")
        elif rel.startswith(".github/workflows/"):
            deferred.append((rel, path, body.get("message", "")))
            print(f"  defer {rel}（token 缺 workflow 权限）")
        else:
            print(f"  FAIL {rel}: {status} {body.get('message')}", file=sys.stderr)

    # 清掉仓库里已有、本地已不再需要的文件（只碰仓库自身的目录，避免误删）
    status, tree = request(token, "GET", f"{base}/git/trees/{branch}?recursive=1")
    wanted = {rel for rel, _ in files}
    if status == 200:
        for item in tree.get("tree", []):
            rel = item["path"]
            if item["type"] != "blob" or rel in wanted:
                continue
            if not (rel.startswith(("tools/", "Lantern/", "ci/")) or "/" not in rel):
                continue
            st, _ = request(token, "DELETE", f"{base}/contents/{urllib.parse.quote(rel)}",
                            {"message": f"remove {rel}", "sha": item["sha"], "branch": branch})
            if st in (200, 201):
                print(f"  del {rel}")
    else:
        print(f"（列目录失败，跳过清理：{status}）", file=sys.stderr)

    if deferred:
        for rel, path, why in deferred:
            target = "ci/build.yml"
            status2, existing2 = request(token, "GET", f"{base}/contents/{target}?ref={branch}")
            payload = {
                "message": f"add {target}（镜像自 {rel}）",
                "content": base64.b64encode(path.read_bytes()).decode(),
                "branch": branch,
            }
            if status2 == 200 and isinstance(existing2, dict):
                payload["sha"] = existing2["sha"]
            st, resp = request(token, "PUT", f"{base}/contents/{target}", payload)
            print(f"  CI 文件改放 {target}: {st} {resp.get('message', '')}")
            print(f"    原因（GitHub 返回）：{why}")

    print(f"\n完成 {ok}/{len(files)}：{repo['html_url']}")
    return 0 if ok + len(deferred) >= len(files) else 6


if __name__ == "__main__":
    sys.exit(main())
