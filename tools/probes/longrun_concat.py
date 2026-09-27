#!/usr/bin/env python3
"""把用户库里的真实录音**只读**拼成一条 ≥120 分钟的 wav（P9-2 的长跑输入）。

为什么是拼接而不是造合成音：这一包要量的是「课堂量级的输入下，接线后的那条
管线内存会不会一直涨」。合成音（`say`）只有几十秒，且音频特征和课堂录音差
很远；库里现成的 48kHz 单声道录音才是真实分布。

**只读打开源文件、只写 --out 指定的临时目录**：不碰用户库里的任何文件。
不用 ffmpeg（派单明令）——标准库 `wave` 够用，源和目标格式一致时可以整块
搬运，不做任何重采样/重编码。

用法：
    python3 tools/probes/longrun_concat.py --out /tmp/p9-2/long.wav [--minutes 120]
"""
import argparse
import os
import sys
import wave

LIB = os.path.expanduser(
    "~/Library/Application Support/ClassroomTranscriber/recordings"
)


def readable(path):
    """返回 (秒数, 帧参数) 或 None。库里有一批 P9-1 记录过的「零头文件」
    （RIFF 头没写完），它们打不开——直接跳过，不要试图修（那是 P9-1 的事，
    而且这里只许读）。"""
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / w.getframerate(), (
                w.getnchannels(), w.getsampwidth(), w.getframerate()
            )
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--minutes", type=float, default=120.0)
    ap.add_argument("--lib", default=LIB)
    # 库里一堆几十秒的碎片（试录/误触）。拼进来只会让拼接点多几十个，
    # 对内存曲线没有任何增量信息，所以默认只挑整段课堂（≥5 分钟）
    ap.add_argument("--min-seconds", type=float, default=300.0)
    args = ap.parse_args()

    target = args.minutes * 60.0
    names = sorted(n for n in os.listdir(args.lib) if n.endswith(".wav"))

    picked, total = [], 0.0
    for name in names:
        path = os.path.join(args.lib, name)
        info = readable(path)
        if info is None:
            print(f"  跳过（打不开）: {name}", file=sys.stderr)
            continue
        seconds, params = info
        if seconds < args.min_seconds:
            continue
        # 按时间顺序（文件名即时间戳）往后接，够 120 分钟就停：跑一趟要按
        # 音频时长的 4-5 倍算墙钟，接得越长跑得越久，够用即止
        picked.append((name, path, seconds, params))
        total += seconds
        if total >= target:
            break

    if total < target:
        sys.exit(f"❌ 可读录音只有 {total:.1f} 秒，凑不够 {target:.0f} 秒")

    formats = {p for _, _, _, p in picked}
    if len(formats) != 1:
        # 参数不一致就得重采样，那不在这一包的范围内（也不该悄悄做）
        sys.exit(f"❌ 挑中的录音格式不一致: {formats}")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    frames = 0
    with wave.open(args.out, "wb") as out:
        for index, (name, path, seconds, params) in enumerate(picked):
            with wave.open(path, "rb") as src:
                if index == 0:
                    out.setparams(src.getparams())  # 其余段格式已核对一致
                while True:
                    block = src.readframes(48000)  # 每块 1 秒，别整段读进内存
                    if not block:
                        break
                    out.writeframes(block)
                    frames += len(block) // (src.getnchannels() * src.getsampwidth())
            print(f"  + {name}  {seconds:.1f}s  累计 {total_of(picked, index):.1f}s")

    written = os.path.getsize(args.out)
    channels, sampwidth, rate = picked[0][3]
    print(f"\n✅ {args.out}")
    print(f"   音频 {frames} 帧 / {rate} Hz = {frames / rate:.1f} 秒 "
          f"({frames / rate / 60:.1f} 分钟)")
    print(f"   字节 {written} = {written / 1048576:.1f} MB")
    print(f"   每分钟增量 {written / (frames / rate / 60):.0f} 字节/分 "
          f"= {written / (frames / rate / 3600) / 1048576:.1f} MB/小时")
    print(f"   构成 ({len(picked)} 条):")
    for name, _, seconds, _ in picked:
        print(f"     {name}  {seconds:.1f}s")


def total_of(picked, index):
    return sum(p[2] for p in picked[: index + 1])


if __name__ == "__main__":
    main()
