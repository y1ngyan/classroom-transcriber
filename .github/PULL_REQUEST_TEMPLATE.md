## 改了什么

## 为什么（对应哪个 issue / 哪种课堂场景）

## 怎么验证的

- [ ] `--selftest` 通过
- [ ] `--speech-gate-selftest` 通过（若未碰门控可跳过）
- [ ] `--ui-snapshot` 对比（若碰了界面，贴前后 PNG）
- [ ] 若碰了 `SpeechGate` / `WhisperWindowPipeline` / 取窗步长：**附真实录音前后对照**
      （取窗数 / 跳过数 / 段数 / 字数 / 覆盖率 并排）
- [ ] 新增断言做过「故意改坏一次、确认会红」的自证

## 没做的事 / 已知风险
