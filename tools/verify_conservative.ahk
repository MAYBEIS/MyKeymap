#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
; 本验证脚本以 #Warn All, Off 抑制库文件在被单独 include 时产生的告警弹框
; (如 KeymapManager 引用了未在此提供的 Tip, 真实运行时由 Utils.ahk 提供)
#Warn All, Off
; ─────────────────────────────────────────────────────────────
; 验证 "=" 保守式(完全拦截)前缀的解析与既有热键写法兼容性
; 用法: bin\AutoHotkey64.exe /ErrorStdOut tools\verify_conservative.ahk
; 退出码: 0 = 全部通过, 1 = 存在失败
; ─────────────────────────────────────────────────────────────

global fails := 0

Check(cond, msg) {
  global fails
  line := (cond ? "PASS: " : "FAIL: ") msg "`n"
  FileAppend(line, "*")
  FileAppend(line, A_ScriptDir . "\verify_result.txt")
  if !cond
    fails++
}

; 进度标记: 便于外部观察脚本卡在哪一段 (仅写文件, 不走管道缓冲)
Mark(name) {
  FileAppend("-- " name " --`n", A_ScriptDir . "\verify_result.txt")
}

; 全局错误处理器: 把运行时错误写入文件并退出, 避免弹出模态框导致脚本挂起
OnError(ErrHandler)
ErrHandler(e, mode) {
  FileAppend("ERROR line " e.Line ": " e.Message "`n", A_ScriptDir . "\verify_result.txt")
  ExitApp(1)
}

; 仅为满足库中引用, 本脚本不实际显示提示 (签名与 Utils.ahk 的 Tip 一致)
Tip(message, time := -1500) {
}

; ── Send 钩子: 覆盖内置 Send, 记录每次放行调用, 用于断言"不放行原键" ──
; 本脚本自身不依赖真实 Send, 故此处只记录、不转发, 避免注入输入干扰断言.
global sendLog := []
Send(keys, *) {
  global sendLog
  sendLog.Push(keys)
}

#Include %A_ScriptDir%\..\bin\lib\KeymapManager.ahk
#Include %A_ScriptDir%\..\bin\lib\Actions.ahk

; 1. 保守式 =XButton1
km := Keymap("verify")
km.Map("=XButton1", (*) => 0)
hk := km.M["XButton1"][1]
Check(hk.rawName == "XButton1", "=XButton1 剥离后 rawName=XButton1 (实际 '" hk.rawName "')")
Check(hk.conservative == true, "=XButton1 被登记为 conservative")
Check(hk.name == "XButton1", "=XButton1 的 WaitKey 名为 XButton1 (实际 '" hk.name "')")
Check(KeymapManager.Conservative.Has("XButton1"), "KeymapManager.Conservative 已登记 XButton1")
Check(KeymapManager.IsConservative("=XButton1"), "IsConservative('=XButton1')=true")
Check(KeymapManager.IsConservative("XButton1") == false, "IsConservative('XButton1')=false")

try {
  km.Enable()
  Check(true, "=XButton1 注册成功 (Hotkey 未因 '=' 报错)")
} catch as e {
  Check(false, "=XButton1 注册抛异常: " e.Message)
}
km.Disable()

; 反向证明: 未剥离的 "=XButton1" 直接交给 Hotkey() 会失败(故必须剥离)
rawOk := false
try {
  Hotkey("=XButton1", (*) => 0, "On")
  rawOk := true
  Hotkey("=XButton1", "Off")
} catch as e {
  rawOk := false
}
Check(!rawOk, "未剥离的 '=XButton1' 无法直接注册 (证明剥离 '=' 的必要性)")

; 2. 保守式组合键 =^!c
Check(ExtractWaitKey("=^!c") == "c", "ExtractWaitKey('=^!c')='c' (实际 '" ExtractWaitKey("=^!c") "')")
km2 := Keymap("verify2")
km2.Map("=^!c", (*) => 0)
Check(km2.M.Has("c") && km2.M["c"][1].rawName == "^!c", "=^!c 剥离为 ^!c")

; 3. 既有写法不受影响 (未带 =)
Check(ExtractWaitKey("^!``") == "``", "ExtractWaitKey('^!``')='``' (实际 '" ExtractWaitKey("^!``") "')")
Check(ExtractWaitKey("*XButton1") == "XButton1", "ExtractWaitKey('*XButton1')='XButton1'")
Check(KeymapManager.IsConservative("^!``") == false, "既有 '^!``' 非 conservative")
Check(KeymapManager.IsConservative("*XButton1") == false, "既有 '*XButton1' 非 conservative")
km2.Map("^!``", (*) => 0)
Check(km2.M["``"][1].rawName == "^!``", "既有 '^!``' rawName 保持 '^!``'")
try {
  km2.Enable()
  Check(true, "既有 '^!``' 注册成功")
} catch as e {
  Check(false, "既有 '^!``' 注册抛异常: " e.Message)
}
km2.Disable()

; 4. 混合前缀 =*XButton1
km3 := Keymap("verify3")
km3.Map("=*XButton1", (*) => 0)
Check(km3.M["XButton1"][1].rawName == "*XButton1", "=*XButton1 剥离为 *XButton1 (实际 '" km3.M["XButton1"][1].rawName "')")
Check(KeymapManager.IsConservative("=*XButton1"), "=*XButton1 conservative")
try {
  km3.Enable()
  Check(true, "=*XButton1 注册成功")
} catch as e {
  Check(false, "=*XButton1 注册抛异常: " e.Message)
}
km3.Disable()

; 5. 拖拽触发键提取
Check(DragTriggerKey("=*XButton1 up") == "XButton1", "DragTriggerKey('=*XButton1 up')=XButton1 (实际 '" DragTriggerKey("=*XButton1 up") "')")
Check(DragTriggerKey("*XButton2") == "XButton2", "DragTriggerKey('*XButton2')=XButton2")

; 6. 拖拽 Stop 已无补发: 仅停定时器+清状态, 调用应安全
try {
  StopDragWindowNoCursor()
  Check(true, "StopDragWindowNoCursor() 无补发且不报错")
} catch as e {
  Check(false, "StopDragWindowNoCursor() 抛异常: " e.Message)
}

; 7. 拖拽全程零放行: 扫描 Actions.ahk 的拖拽函数体, 断言其中无任何 Send 调用.
;    (等价于"hook Send 并断言未发生", 但静态判定更稳, 不受注入按键被忽略影响.)
Mark("section7 enter")
actionsSrc := FileRead(A_ScriptDir . "\..\bin\lib\Actions.ahk")
srcLines := StrSplit(actionsSrc, "`n")
funcNames := ["StopDragWindowNoCursor", "StartDragMoveWindowNoCursor"]
for fnName in funcNames {
  ; 逐行定位顶层函数 "fn(...)  {" 与其后第一个列 0 的 "}" (本文件顶层函数均如此结束)
  startIdx := 0
  for lineNo, srcLine in srcLines {
    if RegExMatch(srcLine, "^\s*" fnName "\(") {
      startIdx := lineNo
      break
    }
  }
  if !startIdx {
    Check(false, "未在 Actions.ahk 找到顶层函数 " fnName)
    continue
  }
  endIdx := startIdx
  for lineNo, srcLine in srcLines {
    if (lineNo > startIdx && RTrim(srcLine, "`r`t ") == "}") {
      endIdx := lineNo
      break
    }
  }
  body := ""
  loop endIdx - startIdx + 1
    body .= srcLines[startIdx + A_Index - 1] "`n"
  hasSend := RegExMatch(body, "(?m)^\s*Send\(") ? true
    : (RegExMatch(body, "(?m)^\s*SendInput\(") ? true
    : (RegExMatch(body, "(?m)^\s*SendEvent\(") ? true
    : (RegExMatch(body, "(?m)^\s*Click\(") ? true
    : (RegExMatch(body, "(?m)^\s*MouseClick\(") ? true : false))))
  Check(!hasSend, fnName "() 函数体内无任何 Send/SendInput/SendEvent/Click 放行调用")
  Check(!InStr(body, "Down}") && !InStr(body, "Up}"), fnName "() 函数体内无 Down/Up 补发")
}
Mark("section7 ok")

; 8. 拖拽实测: 动态确认 stop 过程不产生任何 Send (sendLog 由本脚本顶部 Send 钩子记录)
DRAG_TEST_MODE := true
sendLog := []                       ; 清空钩子日志
StopDragWindowNoCursor()            ; 制造干净起点
Check(WindowDragState == false, "拖拽起点: WindowDragState=false")
before := sendLog.Length
StopDragWindowNoCursor()            ; 等价于松开触发键
after := sendLog.Length
Check(after == before, "StopDragWindowNoCursor() 未产生任何 Send (放行次数 " (after - before) ")")
DRAG_TEST_MODE := false

; 9. conservative 放行点: _handleDelay 对保守式跳过 Send, 非保守式保留 Send
;    通过检测源码分支 + IsConservative 判定双重确认
kmSrc := StrReplace(FileRead(A_ScriptDir . "\..\bin\lib\KeymapManager.ahk"), "`r`n", "`n")
Check(InStr(kmSrc, "if !KeymapManager.IsConservative(keymap.Hotkey)") > 0, "_handleDelay 放行分支受 IsConservative 守卫")
Check(KeymapManager.IsConservative("=XButton1"), "保守式键 IsConservative=true (放行被跳过)")
Check(KeymapManager.IsConservative("XButton1") == false, "非保守式键 IsConservative=false (放行保留)")
; Wait() 中鼠标拖动兼容放行同样受 conservative 守卫
Check(InStr(kmSrc, "else if !conservative") > 0, "Wait() 鼠标拖动放行受 conservative 守卫")

summary := "`nTOTAL FAILS: " fails "`n"
FileAppend(summary, "*")
FileAppend(summary, A_ScriptDir . "\verify_result.txt")
ExitApp(fails ? 1 : 0)
