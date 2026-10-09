/**
 * 移动鼠标到活动窗口中心
 */
MouseToActiveWindowCenter() {
  WinGetPos(&X, &Y, &W, &H, "A")
  MouseMove(x + w / 2, y + h / 2)
}

/**
 * 移动活动窗口位置
 */
MakeWindowDraggable() {
  hwnd := WinExist("A")
  if (WindowMaxOrMin())
    WinRestore("A")

  PostMessage("0x0112", "0xF010", 0)
  Sleep 50
  SendInput("{Right}")
}

; ─────────────────────────────────────────────────────────────
; 拖拽移动窗口 / 拖拽缩放窗口
;
; 按下时只记录基准(窗口几何 + 光标位置 + 抓取偏移), 由 SetTimer 轮询鼠标位移,
; 位移超过死区后才写窗口几何; 松开触发键立即停止.
; 全程使用原生 Win32 物理屏幕坐标(GetCursorPos/GetWindowRect/SetWindowPos),
; 只读光标、写窗口, 绝不调用 MouseMove/SetCursorPos.
; down 热键只记录基准, up 热键(或兜底 GetKeyState)结束.
;
; 拦截策略: 完全拦截, 任何情况下都不补发/放行原触发键 ——
;   未拖动(单击/长按未动)不放行原键(视作什么都没按), 拖动时由拖拽接管.
; ─────────────────────────────────────────────────────────────

global WindowDragState := false
global DRAG_DEADZONE := 4                       ; 死区(px), 超过才认为"开始拖动"
global DRAG_MIN_W := 120, DRAG_MIN_H := 80      ; 缩放的最小宽高
; 调试日志开关(默认关闭). 开启时写 A_ScriptDir\drag_debug.log, 便于真实使用中取证.
global DRAG_DEBUG := false
; 测试开关(默认关闭, 不影响正常运行路径): 置 true 时 Poll 跳过"按键已松开则自停"的兜底,
; 便于测试脚本用真实 SetCursorPos 驱动光标、无需真实按键即可复现/验证坐标路径.
global DRAG_TEST_MODE := false

/**
 * 调试日志 (仅 DRAG_DEBUG=true 时写文件)
 */
DragLog(s) {
  global DRAG_DEBUG
  if !DRAG_DEBUG
    return
  try FileAppend(s "`r`n", A_ScriptDir . "\drag_debug.log", "UTF-8")
}

/**
 * 清空调试日志 (每次 Start 调用)
 */
DragLogReset() {
  global DRAG_DEBUG
  if !DRAG_DEBUG
    return
  try FileDelete(A_ScriptDir . "\drag_debug.log")
}

/**
 * 原生 Win32 读光标物理屏幕坐标 (唯一的光标读取入口)
 *
 * 为什么不用 MouseGetPos: AHK v2 的 CoordMode 是 **线程局部** 的, 且默认值为
 * Client(相对活动窗口). 热键线程执行过 CoordMode("Mouse","Screen") 后,
 * SetTimer 建立的 **定时器线程** 并不会继承该设置, 其 A_CoordModeMouse 仍是
 * 默认 Client. 于是 Start(热键线程, Screen) 记录的基准, 与 Poll(定时器线程,
 * Client) 读到的坐标分属两个坐标系 → 首帧位移暴走(跳变) + 参照系随窗口移动
 * 产生反馈 → 疯狂抖动. 这正是本次的真实根因.
 * GetCursorPos 恒返回物理屏幕坐标, 与线程/CoordMode/DPI 层无关, 从根上杜绝该类问题.
 */
DragRawCursor(&x, &y) {
  pt := Buffer(8, 0)
  DllCall("GetCursorPos", "ptr", pt)
  x := NumGet(pt, 0, "int")
  y := NumGet(pt, 4, "int")
}

/**
 * 原生 Win32 读窗口物理屏幕矩形 (GetWindowRect, 唯一的窗口读取入口)
 */
DragRawRect(hwnd, &x, &y, &w, &h) {
  rc := Buffer(16, 0)
  DllCall("GetWindowRect", "ptr", hwnd, "ptr", rc)
  x := NumGet(rc, 0, "int")
  y := NumGet(rc, 4, "int")
  w := NumGet(rc, 8, "int") - x
  h := NumGet(rc, 12, "int") - y
}

/**
 * 取光标处应操作的**顶层窗口** (物理屏幕坐标入参)
 *
 * WindowFromPoint 可能返回子控件(如记事本的 Edit), 若直接对其 SetWindowPos 只会移动控件本身.
 * 故用 GetAncestor(GA_ROOT=2) 上溯到顶层窗口; 上溯失败再退回 WindowFromPoint 结果.
 */
DragWindowFromPoint(x, y) {
  wfp := DllCall("WindowFromPoint", "int64", (y << 32) | (x & 0xFFFFFFFF), "ptr")
  if !wfp
    return 0
  root := DllCall("GetAncestor", "ptr", wfp, "uint", 2, "ptr")   ; GA_ROOT
  return root ? root : wfp
}

/**
 * 原生 Win32 写窗口物理几何 (SetWindowPos, 唯一的窗口写入入口)
 * flags 见 SWP_*; 调用方保证传 NOZORDER|NOACTIVATE, 避免置顶/激活副作用.
 */
DragSetWindowPos(hwnd, x, y, w, h, flags) {
  DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0, "int", x, "int", y, "int", w, "int", h, "uint", flags)
}

/**
 * 当前线程 DPI 感知上下文句柄
 * 18 == GetThreadDpiAwarenessContext(SetThreadDpiAwarenessContext(-3)) 的句柄值
 * (PER_MONITOR_AWARE_V2)
 */
DragCtx() {
  return DllCall("GetThreadDpiAwarenessContext", "ptr")
}

/**
 * 把本线程 DPI 感知上下文统一为 PER_MONITOR_AWARE(-3), 返回切换前的句柄以便恢复.
 * 在 Start 与每帧 Poll 都调用: 保证 GetCursorPos / GetWindowRect / SetWindowPos
 * 在整个拖拽会话内始终处于同一 DPI 上下文, 杜绝混用导致的坐标系/比例不一致.
 */
DragHarmonizeDpi() {
  raw := DragCtx()
  if (raw != 18)
    try DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")
  return raw
}

/**
 * 恢复切换前的 DPI 上下文句柄 (与 DragHarmonizeDpi 配对)
 */
DragRestoreDpi(raw) {
  if (raw != 18)
    try DllCall("SetThreadDpiAwarenessContext", "ptr", raw, "ptr")
}

/**
 * 从热键名中提取用于 GetKeyState 的物理按键名
 * 注意: up 热键形如 "*XButton1 up", ExtractWaitKey() 会保留 " up" 后缀
 * (空格不在其 Trim 集合内), 必须去掉 " up" 才能被 GetKeyState 正确识别,
 * 否则 GetKeyState("<key> up", "P") 恒为 false, 轮询会首帧自停.
 */
DragTriggerKey(hotkey) {
  return RegExReplace(ExtractWaitKey(hotkey), "i)\s+up$", "")
}

/**
 * 拖拽移动窗口
 * 按下时仅记录基准, 由 SetTimer 轮询鼠标位移后移动窗口.
 */
StartDragMoveWindow() {
  global WindowDragState, DRAG_TEST_MODE
  if WindowDragState
    return
  ; 全程使用原生 Win32 物理屏幕坐标: GetCursorPos / GetWindowRect / SetWindowPos.
  ; 不再依赖 AHK 的 MouseGetPos/WinGetPos/WinMove, 因而与 CoordMode 线程局部性、
  ; AHK DPI 层均无关, 从根上杜绝"Start/Poll 坐标系不一致"导致的跳变与抖动.
  raw := DragHarmonizeDpi()
  DragRawCursor(&mx0, &my0)                    ; 只读光标, 绝不 SetCursorPos
  hwnd := DragWindowFromPoint(mx0, my0)        ; 顶层窗口(自动上溯出子控件)
  if !hwnd
    hwnd := DllCall("GetForegroundWindow", "ptr")
  if !hwnd {
    DragRestoreDpi(raw)
    return
  }
  ; 最小化窗口无几何意义, 跳过
  if (WinGetMinMax(hwnd) = -1) {
    DragRestoreDpi(raw)
    return
  }
  ; 最大化/全屏先还原, 否则无法拖动
  if (WinGetMinMax(hwnd) = 1) {
    WinRestore(hwnd)
    Sleep 50
  }
  DragRawRect(hwnd, &x0, &y0, &w0, &h0)
  WindowDragState := {
    mode: "move",
    hwnd: hwnd,
    key: DragTriggerKey(A_ThisHotkey),
    mx0: mx0, my0: my0,
    x0: x0, y0: y0, w0: w0, h0: h0,
    ox: mx0 - x0, oy: my0 - y0,   ; 抓取点相对窗口左上角的偏移, 移动时保持不变
    lx: x0, ly: y0, lw: w0, lh: h0,   ; 上一帧实际写入的目标矩形(去抖: 相同则跳过写)
    moved: false
  }
  DragLogReset()
  DragLog("[Start move] ctx=" DragCtx() " A_ScreenDPI=" A_ScreenDPI
    . " | cursorScreen=(" mx0 "," my0 ") rect=(" x0 "," y0 "," w0 "," h0 ")"
    . " | ox=" (mx0 - x0) " oy=" (my0 - y0))
  DragRestoreDpi(raw)
  SetTimer(PollDragMoveWindow, 10)
}

/**
 * 拖拽移动窗口 - 轮询 (每帧读取光标, 计算位移, 写窗口位置)
 */
PollDragMoveWindow() {
  global WindowDragState, DRAG_DEADZONE, DRAG_TEST_MODE
  st := WindowDragState
  if !st
    return
  ; 兜底: 触发键已松开则结束, 防止卡死 (DRAG_TEST_MODE 时跳过, 便于测试)
  if !DRAG_TEST_MODE && !GetKeyState(st.key, "P") {
    StopDragWindow()
    return
  }
  if !WinExist("ahk_id " st.hwnd) {   ; 窗口被关闭
    StopDragWindow()
    return
  }
  raw := DragHarmonizeDpi()
  DragRawCursor(&mx, &my)              ; 原生物理屏幕坐标, 与 Start 完全同源
  dx := mx - st.mx0
  dy := my - st.my0
  if !st.moved && (Abs(dx) > DRAG_DEADZONE || Abs(dy) > DRAG_DEADZONE)
    st.moved := true
  if !st.moved {   ; 死区之内不改变窗口位置, 保证按下瞬间窗口不动
    DragLog("[Poll move] ctx=" DragCtx() " mx=" mx " my=" my " dx=" dx " dy=" dy " moved=false (no write)")
    DragRestoreDpi(raw)
    return
  }
  ; 新位置 = 光标 - 恒定抓取偏移, 尺寸不变 ⇒ 抓取点始终吸附光标, 无初始位移
  tgtx := mx - st.ox, tgty := my - st.oy
  ; 去抖: 目标矩形与上一帧一致(无可视变化)则跳过写, 避免冗余 SetWindowPos 引起的抖动
  if (tgtx != st.lx || tgty != st.ly) {
    ; SWP_NOSIZE(0x1)|SWP_NOZORDER(0x4)|SWP_NOACTIVATE(0x10) = 0x15
    DragSetWindowPos(st.hwnd, tgtx, tgty, 0, 0, 0x15)
    st.lx := tgtx, st.ly := tgty
  }
  DragRestoreDpi(raw)
  DragRawRect(st.hwnd, &ax, &ay, &aw, &ah)
  DragLog("[Poll move] ctx=" DragCtx() " mx=" mx " my=" my " dx=" dx " dy=" dy
    . " | tgt=(" tgtx "," tgty ") | actualRect=(" ax "," ay "," aw "," ah ")"
    . " | err=(" (ax - tgtx) "," (ay - tgty) ")")
}

/**
 * 拖拽缩放窗口
 * 按下瞬间不改变尺寸; 鼠标移动后按位移主轴自动选边/角:
 * 水平为主改左右, 垂直为主改上下, 两者都大改角.
 */
StartDragResizeWindow(strategy := "axis") {
  global WindowDragState, DRAG_TEST_MODE
  if WindowDragState
    return
  ; 同移动: 全程原生 Win32 物理屏幕坐标, 与 CoordMode 线程局部性/DPI 层无关.
  raw := DragHarmonizeDpi()
  DragRawCursor(&mx0, &my0)                    ; 只读光标, 绝不 SetCursorPos
  hwnd := DragWindowFromPoint(mx0, my0)        ; 顶层窗口(自动上溯出子控件)
  if !hwnd
    hwnd := DllCall("GetForegroundWindow", "ptr")
  if !hwnd {
    DragRestoreDpi(raw)
    return
  }
  if (WinGetMinMax(hwnd) = -1) {
    DragRestoreDpi(raw)
    return
  }
  if (WinGetMinMax(hwnd) = 1) {
    WinRestore(hwnd)
    Sleep 50
  }
  DragRawRect(hwnd, &x0, &y0, &w0, &h0)
  WindowDragState := {
    mode: "resize",
    hwnd: hwnd,
    key: DragTriggerKey(A_ThisHotkey),
    strategy: strategy,
    mx0: mx0, my0: my0,
    x0: x0, y0: y0, w0: w0, h0: h0,
    lx: x0, ly: y0, lw: w0, lh: h0,   ; 上一帧实际写入的目标矩形(去抖)
    moved: false
  }
  DragLogReset()
  DragLog("[Start resize/" strategy "] ctx=" DragCtx() " A_ScreenDPI=" A_ScreenDPI
    . " | cursorScreen=(" mx0 "," my0 ") rect=(" x0 "," y0 "," w0 "," h0 ")")
  DragRestoreDpi(raw)
  SetTimer(PollDragResizeWindow, 10)
}

/**
 * 拖拽缩放窗口 - 轮询 (按位移主轴自动选边/角)
 */
PollDragResizeWindow() {
  global WindowDragState, DRAG_DEADZONE, DRAG_MIN_W, DRAG_MIN_H, DRAG_TEST_MODE
  st := WindowDragState
  if !st
    return
  if !DRAG_TEST_MODE && !GetKeyState(st.key, "P") {
    StopDragWindow()
    return
  }
  if !WinExist("ahk_id " st.hwnd) {
    StopDragWindow()
    return
  }
  raw := DragHarmonizeDpi()
  DragRawCursor(&mx, &my)              ; 原生物理屏幕坐标, 与 Start 完全同源
  dx := mx - st.mx0
  dy := my - st.my0
  if !st.moved && (Abs(dx) > DRAG_DEADZONE || Abs(dy) > DRAG_DEADZONE)
    st.moved := true
  if !st.moved {   ; 满足"按下瞬间不改变尺寸"
    DragLog("[Poll resize] ctx=" DragCtx() " mx=" mx " my=" my " dx=" dx " dy=" dy " moved=false (no write)")
    DragRestoreDpi(raw)
    return
  }

  ; 默认左上角固定, 右/下边跟随鼠标
  nx := st.x0, ny := st.y0, nw := st.w0, nh := st.h0
  if (st.strategy = "bottomright") {
    ; 策略(b): 固定右下角, 宽高直接跟随位移
    nw := st.w0 + dx
    nh := st.h0 + dy
  } else {
    ; 策略(a): 按位移主轴自动选边/角
    ax := Abs(dx), ay := Abs(dy)
    if (ax > ay * 2) {
      nw := st.w0 + dx                       ; 水平为主: 只改左右边
    } else if (ay > ax * 2) {
      nh := st.h0 + dy                       ; 垂直为主: 只改上下边
    } else {
      nw := st.w0 + dx                       ; 两者都大: 同时改角
      nh := st.h0 + dy
    }
  }
  nw := Max(nw, DRAG_MIN_W)   ; 最小尺寸钳制
  nh := Max(nh, DRAG_MIN_H)
  ; 去抖: 目标矩形与上一帧一致(无可视变化)则跳过写
  if (nx != st.lx || ny != st.ly || nw != st.lw || nh != st.lh) {
    ; SWP_NOMOVE(0x2)|SWP_NOZORDER(0x4)|SWP_NOACTIVATE(0x10) = 0x16
    DragSetWindowPos(st.hwnd, nx, ny, nw, nh, 0x16)
    st.lx := nx, st.ly := ny, st.lw := nw, st.lh := nh
  }
  DragRestoreDpi(raw)
  DragRawRect(st.hwnd, &ax2, &ay2, &aw2, &ah2)
  DragLog("[Poll resize] ctx=" DragCtx() " mx=" mx " my=" my " dx=" dx " dy=" dy
    . " | tgt=(" nx "," ny "," nw "," nh ") | actualRect=(" ax2 "," ay2 "," aw2 "," ah2 ")"
    . " | err=(" (ax2 - nx) "," (ay2 - ny) "," (aw2 - nw) "," (ah2 - nh) ")")
}

/**
 * 结束拖拽 (移动/缩放共用) - 停定时器并清理
 *
 * 拦截策略: 完全拦截, 不补发原键.
 *   无论是否拖动、无论按住时长, 都绝不放行原触发键(未拖动 = 什么都没按).
 *   本函数只负责: 停掉轮询定时器 + 清空拖拽状态, 保证按键不卡住.
 */
StopDragWindow() {
  global WindowDragState
  SetTimer(PollDragMoveWindow, 0)
  SetTimer(PollDragResizeWindow, 0)
  WindowDragState := false
}

/**
 * 启动程序或切换到程序
 * @param {string} winTitle AHK中的WinTitle
 * @param {string} target 程序的路径
 * @param {string} args 参数
 * @param {string} workingDir 工作文件夹
 * @param {bool} admin 是否为管理员启动
 * @param {bool} isHide 窗口是否为隐藏窗口
 * @returns {void} 
 */
ActivateOrRun(winTitle := "", target := "", args := "", workingDir := "", admin := false, isHide := false, runInBackground := false) {
  ; 如果是程序或参数中带有“选中的文件” 则通过该程序打开该连接
  if (InStr(target, "{selected}") || InStr(args, "{selected}")) {
    ; 没有获取到文字直接返回
    if not (ReplaceSelectedText(&target, &args))
      return
  }

  ; 切换程序
  winTitle := Trim(winTitle)
  if (winTitle && activateWindow(winTitle, isHide))
    return

  ; 程序没有运行，运行程序
  if not target {
    return
  }
  workingDir := workingDir ? workingDir : A_WorkingDir
  RunPrograms(target, args, workingDir, admin, runInBackground)
}

/**
 * 轮换程序窗口
 * @param winTitle AHK中的WinTitle
 * @param hwnds 活动窗口的句柄数组
 * @returns {void|number} 
 */
LoopRelatedWindows(winTitle?, hwnds?) {
  ; 如果没有传句柄数组则获取当前窗口的
  if not (IsSet(hwnds)) {
    predicate := (hwnd) => WinGetTitle(hwnd) != ""
    if (GetProcessName() == "explorer.exe") {
      predicate := (hwnd) => WinGetClass(hwnd) = "CabinetWClass"
    }
    hwnds := FindWindows("ahk_exe " WinGetProcessName("A"), predicate)
  }

  ; 只有一个窗口显示出来就行
  if (hwnds.Length = 1) {
    WinActivate(hwnds.Get(1))
    return
  }

  ; 没有传winTitle时，则获取当前程序的名称
  if not (IsSet(winTitle)) {
    class := WinGetClass("A")
    if (class == "ApplicationFrameWindow") {
      winTitle := WinGetTitle("A") "  ahk_class ApplicationFrameWindow"
    } else {
      winTitle := "ahk_exe " GetProcessName()
    }
  }
  winTitle := Trim(winTitle)

  static winGroup, lastWinTitle := "", lastHwnd := "", gi := 0
  if (winTitle != lastWinTitle || lastHwnd != WinExist("A")) {
    lastWinTitle := winTitle
    winGroup := "AutoName" gi++
  }

  ; 将所有的hwnd都添加到组里
  for hwnd in hwnds {
    GroupAdd(winGroup, "ahk_id" hwnd)
  }

  ; 切换
  lastHwnd := GroupActivate(winGroup, "R")
  return lastHwnd
}

/**
 * CapsLock 命令框
 */
EnterCapslockAbbr(capsHook) {
  static WM_USER := 0x0400
  static SHOW_COMMAND_INPUT := WM_USER + 0x0001
  static HIDE_COMMAND_INPUT := WM_USER + 0x0002
  static CANCEL_COMMAND_INPUT := WM_USER + 0x0003

  ; 高级键盘设置 > 输入语言热键, 用户勾选了用 Shift 键关闭大写
  ; if GetKeyState("Shift", "P") {
  ;   Tip("bug: Shift key is pressed down")
  ;   return
  ; }

  ; 显示命令框窗口
  PostMessageToCpasAbbr(SHOW_COMMAND_INPUT)

  endReason := StartInputHook(capsHook)
  if (InStr(endReason, "Match")) {
    char := SubStr(capsHook.Match, -1)
    PostCharToCaspAbbr(, char)
    SetTimer(HideCaspAbbr, -1)
  } else {
    if (InStr(endReason, "EndKey")) {
      PostMessageToCpasAbbr(CANCEL_COMMAND_INPUT)
    } else {
      PostMessageToCpasAbbr(HIDE_COMMAND_INPUT)
    }
  }

  if (capsHook.Match) {
    ExecCapslockAbbr(capsHook.Match)
  }
}

/**
 * semi缩写框
 */
EnterSemicolonAbbr(semiHook, semiHookAbbrWindow) {
  semiHookAbbrWindow.Show(" ")
  endReason := StartInputHook(semiHook)
  if (InStr(endReason, "Match")) {
    char := SubStr(semiHook.Match, -1)
    semiHookAbbrWindow.Show(char, true)
    SetTimer(() => semiHookAbbrWindow.Hide(), -100)
  } else {
    semiHookAbbrWindow.Hide()
  }

  if (semiHook.Match)
    ExecSemicolonAbbr(semiHook.Match)
}

/**
 * 智能的关闭窗口
 */
SmartCloseWindow() {
  if NotActiveWin() {
    return
  }

  class := WinGetClass("A")
  name := GetProcessName()
  if (WinActive("- Microsoft Visual Studio ahk_exe devenv.exe")) {
    Send("^{F4}")
  } else {
    if (class == "ApplicationFrameWindow" || name == "explorer.exe") {
      Send("!{F4}")
    } else {
      PostMessage(0x112, 0xF060, , , "A")
    }
  }
}

/**
 * 窗口居中并修改其大小
 * @param width 窗口宽度
 * @param height 窗口高度
 * @returns {void} 
 */
CenterAndResizeWindow(width, height) {
  if NotActiveWin() {
    return
  }

  ; 在 mousemove 时需要 PER_MONITOR_AWARE (-3), 否则当两个显示器有不同的缩放比例时, mousemove 会有诡异的漂移
  ; 在 winmove 时需要 UNAWARE (-1), 这样即使写死了窗口大小为 1200x800, 系统会帮你缩放到合适的大小
  try DllCall("SetThreadDpiAwarenessContext", "ptr", -1, "ptr")

  WinExist("A")
  if (WindowMaxOrMin())
    WinRestore

  WinGetPos(&x, &y, &w, &h)

  ms := GetMonitorAt(x + w / 2, y + h / 2)
  MonitorGetWorkArea(ms, &l, &t, &r, &b)
  w := r - l
  h := b - t

  winW := Min(width, w)
  winH := Min(height, h)
  winX := l + (w - winW) / 2
  winY := t + (h - winH) / 2

  WinMove(winX, winY, winW, winH)
  try DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")
}

/**
 * 窗口最大化
 */
MaximizeWindow() {
  if NotActiveWin() {
    return
  }

  if WindowMaxOrMin() {
    WinRestore("A")
  } else {
    WinMaximize("A")
  }
}

/**
 * 窗口最小化
 */
MinimizeWindow() {
  if (NotActiveWin() || WinGetProcessName("A") == "Rainmeter.exe")
    return

  WinMinimize("A")
}

/**
 * 窗口置顶
 */
ToggleWindowTopMost() {
  value := !(WinGetExStyle("A") & 0x8)
  WinSetAlwaysOnTop(value, "A")
  if value {
    Tip(Translation().always_on_top_on)
  } else {
    Tip(Translation().always_on_top_off)
  }
}

/**
 * 模拟 Alt+Tab 热键
 */
SystemAltTab() {
  global altTabIsOpen := true
  send("^!{Tab}")
}

/**
 * 模拟 Shift+Alt+Tab 热键
 */
SystemShiftAltTab() {
  global altTabIsOpen := true
  send("^+!{Tab}")
}

/**
 * 关闭窗口（直接杀进程）
 * @returns  
 */
CloseWindowProcesses() {
  if NotActiveWin() {
    return
  }

  name := WinGetProcessName("A")
  ; 如果删了explorer会导致桌面白屏
  if (name == "explorer.exe") {
    CloseSameClassWindows()
    return
  }

  Run('taskkill /f /im "' name '"', , "Hide")
}

/**
 * 将鼠标移动到光标的位置
 */
MoveMouseToCaret() {
  GetCaretPos(&x, &y)
  if (StrLen(x) | StrLen(y)) {
    ; Tip(A_SendMode "|" A_CoordModeMouse) ; 每次执行热键, 这两个都会重置为默认值
    SendMode("Event")
    CoordMode("Mouse", "Screen")
    MouseMove(x, y, 100)
  } else {
    MouseToActiveWindowCenter()
  }
}

/**
 * 修改文本颜色字体
 * @param {string} color HEX颜色值
 * @param {string} fontFamily 字体
 */
changeTextStyle(color := "#000000", fontFamily := "Iosevka") {
  text := GetSelectedText()
  loop StrLen(text) {
    Send("{Del}")
  }
  if not (text) {
    return
  }

  if (WinActive("ahk_group makrdownGroup")) {
    text := "<font color='" color "'>" text "</font>"
  } else {
    text := FormatHtmlStyle(text, color, fontFamily)
  }

  PasteToPrograms(text)
}

/**
 * 中英文之间添加空格
 */
InsertSpaceBetweenZHAndEn() {
  text := GetSelectedText()
  text := RegExReplace(text, "([\x{4e00}-\x{9fa5}])(?=[a-zA-Z0-9])|([a-zA-Z0-9])(?=[\x{4e00}-\x{9fa5}])", "$0 ")
  PasteToPrograms(text)
}

/**
 * 按住左Shift
 */
HoldDownLShiftKey() {
  send("{LShift down}")
  key := ExtractWaitKey(A_ThisHotkey)
  keywait(key)
  send("{LShift up}")
}


HoldDownModifierKey(modifier) {
  send("{" modifier " down}")
  key := ExtractWaitKey(A_ThisHotkey)
  keywait(key)
  send("{" modifier " up}")
}

/**
 * 按住右Shift
 */
HoldDownRShiftKey() {
  send("{RShift down}")
  key := LTrim(A_ThisHotkey, "*")
  keywait(key)
  send("{RShift up}")
}

/**
 * 绑定当前窗口到当前键上
 * @param key 当前键
 * @returns {void} 
 */
BindWindow() {
  windowID := false
  windowTitle := false
  handler(thisHotKey) {
    waitkey := ExtractWaitKey(thisHotKey)
    if not (KeyWait(waitkey, "T0.6")) {
      ; 绑定窗口
      windowID := WinGetID("A")
      windowTitle := WinGetTitle("A")
      Tip("已绑定当前窗口")
      KeyWait(waitkey, "T2") ; 避免按住时每隔 0.6 秒重复执行这个动作
      return
    }

    if (windowID && WinExist("ahk_id " windowID)) {
      if WinActive() {
        WinMinimize
        return
      }
      WinActivate(windowID)
      return
    }

    if (windowTitle && WinExist(windowTitle)) {
      if WinActive() {
        WinMinimize
        return
      }
      WinActivate(windowTitle)
      return
    }

    Tip("请长按绑定窗口")
  }

  return handler
}

/**
 * 关闭同应用的所有窗口
 */
CloseSameClassWindows() {
  if NotActiveWin() {
    return
  }

  exe := WinGetProcessName("A")
  if exe == "explorer.exe" {
    windows := FindWindows("ahk_class " WinGetClass("A"))
  } else {
    windows := FindWindows("ahk_exe " exe)
  }

  for i, hwnd in windows {
    WinClose(hwnd)
  }
}

/**
 * 锁屏
 */
SystemLockScreen() {
  Sleep 300
  DllCall("LockWorkStation")
}

/**
 * 关机
 */
SystemShutdown() {
  Run("SlideToShutDown.exe")
  sleep(1300)
  CoordMode("Mouse", "Screen")
  MouseClick("Left", 100, 100)
}

/**
 * 重启
 */
SystemReboot() {
  Shutdown(2)
}

SystemSleep() {
  DllCall("PowrProf\SetSuspendState")
}

SystemRestartExplorer() {
  Run("tools\Rexplorer_x64.exe /I /R")
}

SoundControl() {
  wnd := WinExist("A")
  if wnd {
    ActivateOrRun(, "bin\SoundControl.exe", "PreviousWindow " wnd)
  } else {
    ActivateOrRun(, "bin\SoundControl.exe")
  }
}

BrightnessControl() {
  Run("MyKeymap.exe /script bin\ChangeBrightness.ahk")
}

GoToLastWindow() {
  Send("!{tab}")
}

GoToPreviousVirtualDesktop() {
  Send("^#{left}")
}

GoToNextVirtualDesktop() {
  Send("^#{right}")
}

MoveWindowToNextMonitor() {
  Send("#+{right}")
}

/**
 * 切换Capslock状态
 */
ToggleCapslock() {
  if GetKeyState("Alt", "P")
    send("{blind}{LCtrl}{LAlt Up}")
  send("{blind}{CapsLock}")
}

/**
 * 查看帮助
 */
openHelpHtml() {
  if FileExist("bin\site\help.html") {
    Run("bin\site\help.html")
  } else {
    MsgBox("帮助文件未生成，需要打开设置点一下保存")
  }
}

/**
 * 设置窗口位置
 * @param x 窗口左上角X轴
 * @param y 窗口左上角Y轴
 * @param width 窗口宽度
 *   default: 不做修改
 * @param height 窗口高度
 *   default: 不做修改
 */
SetWindowPositionAndSize(x, y, width, height) {
  if NotActiveWin() {
    return
  }

  hwnd := WinExist("A")
  statie := WinGetMinMax()
  if statie
    WinRestore

  if (width == "default" || height == "default") {
    offset := GetWindowPositionOffset(hwnd)
    width := width == "default" ? offset.w : width
    height := height == "default" ? offset.h : height
  }

  WinMove(x, y, width, height)
}

/**
 * 一次打开多个链接或程序
 * @param urls 链接或程序 
 */
LaunchMultiple(urls*) {
  for index, url in urls {
    ShellRun(url)
  }
}

/**
 * 进程存在时用热键激活、否则启动程序
 */
ProcessExistSendKeyOrRun(pname, key, target) {
  if ProcessExist(pname) {
    Send(key)
  } else {
    RunPrograms(target)
  }
}

/**
 * 包裹选中的文本
 * @param Format 格式
 */
WrapSelectedText(Format) {
  text := GetSelectedText()
  if text {
    PasteToPrograms(StrReplace(format, "{text}", text))
  }
}

CopySelectedAsPlainText() {
  A_Clipboard := ""
  Send "^c"
  if !ClipWait(1) {
    Tip(Translation().copy_failed)
    return
  }
  A_Clipboard := A_Clipboard
  Tip(Translation().copy_ok)
}

MuteActiveApp() {
  code := RunWait("bin\SoundControl.exe ToggleMute " GetActiveProcess("name"))
  switch code {
    case 1: Tip(Translation().mute_on)
    case 2: Tip(Translation().mute_off)
    default: Tip(Translation().mute_falied)
  }
}

ShowActiveProcessInFolder() {
  try path := GetActiveProcess("path")
  catch as e {
    Tip(e.Message)
    return
  }
  ShowFileInFoler(path)
}

chromeInstance() {
  static m := Map()
  key := A_ThisHotkey

  if !m.Has(key) || (m.Has(key) && !WinExist(m.Get(key))) {
    oldWindow := WinActive("A")
    Run("C:\Program Files\Google\Chrome\Application\chrome.exe")
    if !WinWaitNotActive(oldWindow, , 0.2) || !WinWaitActive("ahk_exe chrome.exe", , 0.2) {
      Tip("启动 chrome 失败")
      return
    }
    m.Set(key, WinActive("A"))
    return
  }

  id := WinExist(m.Get(key))
  if WinActive(id) {
    WinMinimize(id)
  } else {
    WinActivate(id)
  }
}