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
   - 只检查当前可见按钮；
   - 按优先级查找：`关闭右侧边栏`、`收起右侧边栏`、`关闭`、`Close`、`退出全屏`、`收起`、`返回`；
   - 点击对应按钮，关闭右侧栏/文件/工具面板；
   - 失败时向 `document`/`window` 派发 Escape 键；
4. 始终返回 `true`，吞掉系统返回手势，避免直接退出应用。

## 验证

- 设置页按返回（keyEvent BACK）：设置关闭，应用不退出；
- 从设置返回到侧边栏；
- 侧边栏再次返回：回到主页面；
- 右上角“工作区文件”面板按返回：面板收起，回到会话页；
- “新建终端”按返回：先关闭原生终端；
- “更多工具”按返回：关闭工具面板；
- hilog：
  ```text
  DSH-WEB: back overlay result "close"
  DSH-WEB: back: handled by overlay fallback
  ```

根页面没有可返回层时返回手势被吞掉，退出应用请使用系统 Home/上滑或最近任务。


## 横向滑动手势（v392）

- 首页（“探索未至之境”）：左滑打开右侧栏，右滑打开左侧栏；
- 其他页面：左滑优先关闭当前浮层/右栏，回到首页；
- 使用 ArkUI `PanGesture`，与系统返回手势并存；
- 全屏沉浸式：移除 ArkTS 的安全区 padding，顶部和底部不再保留状态栏/导航条空白。


## 首页边缘右滑

HarmonyOS 左侧边缘右滑会先触发系统返回事件。v393 在首页的 `onBackPress()` 中检测“探索未至之境”，
如果首页且左侧栏未打开，则点击“打开侧边栏”，从而让边缘右滑也能打开左上角侧栏。


## 系统侧滑返回热区关闭（v395）

v395 在 `EntryAbility.makeImmersive()` 中调用：

```ts
win.setGestureBackEnabled(false)
```

关闭系统侧滑返回热区，左右边缘滑动交给应用内 `PanGesture`：

- 左侧边缘右滑 → 打开左上角侧栏；
- 右侧边缘左滑 → 打开右上角侧栏；
- 首页/其他页面都按当前页面规则处理。

这样解决 HarmonyOS 抢占左边缘右滑、导致左右滑都打开左侧栏的问题。
