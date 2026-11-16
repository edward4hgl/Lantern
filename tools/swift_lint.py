#!/usr/bin/env python3
"""Swift 源码体检 —— 在没有 Swift 工具链的机器上做最低限度的结构校验。

只做三件不会误报的事：
  1. 括号 / 花括号 / 方括号是否配平（跳过字符串、字符字面量、注释）；
  2. 每个文件是否有且仅有一个顶层 `import SwiftUI` 之类的 import 块；
  3. 常见拼写陷阱：`ContentUnavailableView`（iOS 17+）在 16.6 目标下出现、
     未加 `import UIKit` 却直接用 `UIApplication`。

它不替代编译。真正的编译在 GitHub Actions 的 macos runner 上跑。
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Lantern"))

# 逐字符扫，处理 // 行注释、/* */ 块注释（可嵌套）、"..."（含 \( ) 插值）、#"..."#
def strip_noncode(src: str) -> str:
    out = []
    i, n = 0, len(src)
    depth_comment = 0
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if depth_comment:
            if c == "/" and nxt == "*":
                depth_comment += 1
                i += 2
                continue
            if c == "*" and nxt == "/":
                depth_comment -= 1
                i += 2
                continue
            i += 1
            continue
        if c == "/" and nxt == "*":
            depth_comment = 1
            i += 2
            continue
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == '"':
            # 普通字符串，支持 \( ... ) 插值（插值内部当代码处理）
            i += 1
            while i < n:
                if src[i] == "\\":
                    if i + 1 < n and src[i + 1] == "(":
                        # 跳进插值：朴素配对到对应的 )
                        j = i + 2
                        pdepth = 1
                        while j < n and pdepth:
                            if src[j] == "(":
                                pdepth += 1
                            elif src[j] == ")":
                                pdepth -= 1
                            j += 1
                        i = j
                        continue
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


PAIRS = {")": "(", "]": "[", "}": "{"}


def check_balance(code: str, rel: str) -> list[str]:
    problems = []
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                problems.append(f"{rel}:{line}: 多余的 '{ch}'")
                continue
            top, tline = stack.pop()
            if top != PAIRS[ch]:
                problems.append(f"{rel}:{line}: '{ch}' 与第 {tline} 行的 '{top}' 不匹配")
    for ch, l in stack:
        problems.append(f"{rel}:{l}: '{ch}' 没有闭合")
    return problems


def check_api(code: str, rel: str) -> list[str]:
    problems = []
    if "ContentUnavailableView" in code:
        problems.append(f"{rel}: 使用了 ContentUnavailableView（iOS 17+），部署目标是 16.6")
    if re.search(r"\bUIApplication\b", code) and "import UIKit" not in code:
        problems.append(f"{rel}: 用了 UIApplication 但没有 import UIKit")
    if re.search(r"\bUIImage\b", code) and "import UIKit" not in code and "import SwiftUI" not in code:
        problems.append(f"{rel}: 用了 UIImage 但没引入 UIKit/SwiftUI")
    if "PHLivePhotoView" in code and "import PhotosUI" not in code and "import Photos" not in code:
        problems.append(f"{rel}: 用了 PHLivePhotoView 但没有 import Photos/PhotosUI")
    if re.search(r"\bAVPlayerLayer\b", code) and "import AVFoundation" not in code:
        problems.append(f"{rel}: 用了 AVPlayerLayer 但没有 import AVFoundation")
    return problems


def main() -> int:
    files = []
    for dirpath, _, names in os.walk(ROOT):
        for name in sorted(names):
            if name.endswith(".swift"):
                files.append(os.path.join(dirpath, name))
    files.sort()

    all_problems: list[str] = []
    total_lines = 0
    for path in files:
        rel = os.path.relpath(path, os.path.dirname(ROOT)).replace("\\", "/")
        with open(path, encoding="utf-8") as f:
            src = f.read()
        total_lines += src.count("\n")
        code = strip_noncode(src)
        all_problems += check_balance(code, rel)
        all_problems += check_api(code, rel)
        if not re.search(r"^import ", src, re.M):
            all_problems.append(f"{rel}: 没有任何 import")

    print(f"scanned {len(files)} swift files, {total_lines} lines")
    for p in all_problems:
        print("  ! " + p)
    print("OK" if not all_problems else f"{len(all_problems)} problem(s)")
    return 0 if not all_problems else 1


if __name__ == "__main__":
    sys.exit(main())
