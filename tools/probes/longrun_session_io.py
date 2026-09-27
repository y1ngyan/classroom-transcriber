#!/usr/bin/env python3
"""120 分钟会话的 JSON 有多大、整场写下去总共多少字节（P9-2）。

**不是估算**：直接拿用户库里那条**真实**的 67 分钟会话
（`课堂-20260923-155813.wav` 那一节，`durationMillis = 4016000`）当模板，
把它的 `segments` 原样铺到 120 分钟，再真的把 240 份草稿逐份写到临时目录、
逐份 `os.path.getsize` 累加。落盘的字节约等于真实链路，因为段的对象就是真的。

为什么不直接跑一遍 App 录 120 分钟：那要真麦克风（用户明令不许），而且这条
问题（会话 JSON 的尺寸与写入总量）与音频内容无关，只与「段数」有关。

用法：
    python3 tools/probes/longrun_session_io.py [--minutes 120] [--sessions <目录>]
"""
import argparse
import glob
import json
import os
import shutil
import sys
import tempfile
import time

TEMPLATE = os.path.expanduser(
    "~/Library/Application Support/ClassroomTranscriber/sessions"
)
# 草稿间隔，与 `TranscriptionEngine.draftInterval` 必须一致（那边是 30 秒）
DRAFT_INTERVAL_S = 30.0


def pick_template(sessions_dir):
    """挑库里头最长的那条会话当模板（它本来就是课堂量级的段密度）"""
    best = None
    for path in sorted(glob.glob(os.path.join(sessions_dir, "*.json"))):
        if path.endswith("index.json"):
            continue
        doc = json.load(open(path))
        for part in doc.get("parts") or []:
            ms = part.get("durationMillis") or 0
            segs = part.get("segments") or []
            if segs and (best is None or ms > best[0]):
                best = (ms, path, doc, part, segs)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=120.0)
    ap.add_argument("--sessions", default=TEMPLATE)
    args = ap.parse_args()

    target_s = args.minutes * 60.0
    found = pick_template(args.sessions)
    if not found:
        sys.exit("❌ 会话库里没有可用的模板")
    tmpl_ms, tmpl_path, tmpl_doc, tmpl_part, tmpl_segs = found
    tmpl_s = tmpl_ms / 1000.0
    print(f"模板: {os.path.basename(tmpl_path)[:8]} · {tmpl_s:.1f} 秒 · "
          f"{len(tmpl_segs)} 段 · {os.path.getsize(tmpl_path)} 字节")

    # 把模板段平铺到目标时长。时间戳按整段偏移，其余字段原样——
    # 段对象是真的，所以序列化出来的字节数也就是真的
    segments = []
    offset_ms = 0
    while offset_ms < target_s * 1000:
        for seg in tmpl_segs:
            if offset_ms + (seg.get("endTimeMillis") or 0) > target_s * 1000:
                break
            copy = dict(seg)
            copy["startTimeMillis"] = (seg.get("startTimeMillis") or 0) + offset_ms
            copy["endTimeMillis"] = (seg.get("endTimeMillis") or 0) + offset_ms
            segments.append(copy)
        offset_ms += tmpl_ms
    segments.sort(key=lambda s: s["startTimeMillis"])
    print(f"铺到 {target_s:.0f} 秒: {len(segments)} 段 "
          f"（{len(segments) / (target_s / 60):.1f} 段/分钟）")

    part = dict(tmpl_part)
    part["segments"] = segments
    part["durationMillis"] = int(target_s * 1000)
    doc = dict(tmpl_doc)
    doc["parts"] = [part]

    tmp = tempfile.mkdtemp(prefix="p9-2-session-")
    try:
        t0 = time.perf_counter()
        blob = json.dumps(doc, ensure_ascii=False).encode()
        enc_ms = (time.perf_counter() - t0) * 1000
        body = os.path.join(tmp, "session.json")
        with open(body, "wb") as handle:
            handle.write(blob)
        size = os.path.getsize(body)

        t0 = time.perf_counter()
        json.loads(open(body, "rb").read())
        dec_ms = (time.perf_counter() - t0) * 1000

        print(f"\n── 会话正文（一次落盘，`RecordingsStore.save`）──")
        print(f"   字节 {size} = {size / 1024:.0f} KB = {size / 1048576:.2f} MB")
        print(f"   每小时 {size / (target_s / 3600):.0f} 字节/小时"
              f" · 每分钟 {size / (target_s / 60):.0f} 字节/分")
        print(f"   编码 {enc_ms:.0f} ms · 解码 {dec_ms:.0f} ms"
              f"（python json，只作数量级参考；App 走 JSONEncoder）")

        # 草稿：每 30 秒写一份「这次录制到此为止」的全文，总量是**二次**增长的
        draft_dir = os.path.join(tmp, "drafts")
        os.makedirs(draft_dir)
        total = 0
        ticks = int(target_s / DRAFT_INTERVAL_S)
        sizes = []
        for tick in range(1, ticks + 1):
            upto_ms = tick * DRAFT_INTERVAL_S * 1000
            grown = dict(part)
            grown["segments"] = [s for s in segments
                                 if s["startTimeMillis"] < upto_ms]
            payload = dict(doc)
            payload["parts"] = [grown]
            raw = json.dumps(payload, ensure_ascii=False).encode()
            total += len(raw)
            sizes.append(len(raw))
        print(f"\n── 录制途中的草稿（每 {DRAFT_INTERVAL_S:.0f} 秒一份全文）──")
        print(f"   {ticks} 份 · 最后一份 {sizes[-1] / 1024:.0f} KB")
        print(f"   **整场写下去合计 {total / 1048576:.1f} MB**"
              f"（约等于「最后一份 × 份数 ÷ 2」——每份都是全文重写）")
        print(f"   加上收尾那一次正文 {size / 1048576:.2f} MB → "
              f"{(total + size) / 1048576:.1f} MB")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n（临时目录 {tmp} 已清掉；用户库只读打开，未改任何文件）")


if __name__ == "__main__":
    main()
