# Vendor/DiarizeHelper —— C-1 原型搬进主树

这个目录是 `~/ClassroomTranscriber-spike/C-helper`（C-1 冻结原型）的**拷贝**，
按 C-3-1 派单第 1 条搬进主树，好让 `build.sh` 能构建它。

## 与冻结版的差异

**只有 `Package.swift` 的两处注释。** 代码一个字没动。核查：

```bash
diff -r --exclude=.build --exclude=.git --exclude=INTEGRATION.md \
    ~/ClassroomTranscriber-spike/C-helper Vendor/DiarizeHelper
```

输出应当只有 `Package.swift` 的两段注释差异（原型说明 + 依赖说明）。
`Sources/DiarizeHelper/*.swift` 的 diff **必须为空**——那是 C-1 冻结的行为，
App 侧的信封解析、退出码分类、5 条校验全都照着它写。

## 依赖指向哪

`Package.swift` 写的是 `.package(path: "../FluidAudio")`，在这棵树里就是
`Vendor/FluidAudio` —— 一个钉在 commit `5c51c5c` 的 **git submodule**。

**为什么保留 path 依赖、不换成 url 依赖**：submodule 的检出、钉版、以及
「缺了要响亮失败」由 `build.sh` **一处**把关；换成 url 依赖等于让 SwiftPM
自己 clone，那个过程不钉 commit（拉的是默认分支 HEAD），失败形态也不归 build.sh
管。一处实现比两处实现好，理由是「说话人模型在哪」那条的同一个理由。

## 二进制不进仓库

`swift build` 的产物落在 `Vendor/DiarizeHelper/.build/`（已 gitignore）。
构建完只把 `diarize-helper` 这一个可执行文件拷进 app bundle 的
`Contents/MacOS/`，仓库里不留任何二进制。
