# DSH HOS 返回手势处理

## 问题

DSH Web 是单页应用（SPA），设置、侧边栏、关于等浮层不会向浏览器写入 history。
ArkUI 页面 `onBackPress()` 原先只在终端打开时处理返回，其余情况返回 `false`，
系统于是直接结束 EntryAbility，表现为左滑返回手势直接退出应用。

## 实现

`Index.onBackPress()` 的顺序：

1. 如果右侧原生终端打开，先关闭终端；
2. 如果 ArkWeb 有历史（`accessBackward()`），调用 `controller.backward()`；
3. 否则执行 Web 侧兜底脚本：
   - 查找带“关闭/Close/收起/返回”aria-label 或文本的按钮并点击；
   - 失败时向 `document`/`window` 派发 Escape 键；
4. 始终返回 `true`，吞掉系统返回手势，避免直接退出应用。

## 验证

- 设置页按返回（keyEvent BACK）：设置关闭，应用不退出；
- 从设置返回到侧边栏；
- 侧边栏再次返回：回到主页面；
- hilog：
  ```text
  DSH-WEB: back overlay result "close"
  DSH-WEB: back: handled by overlay fallback
  ```

根页面没有可返回层时返回手势被吞掉，退出应用请使用系统 Home/上滑或最近任务。
