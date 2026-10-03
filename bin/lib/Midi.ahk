/**
 * Midi.ahk — MyKeymap MIDI 音符动作运行时 (AutoHotkey v2)
 *
 * 作用:
 *   把按键的按下/松开翻译为 MIDI NoteOn/NoteOff, 输出到虚拟 MIDI 端口,
 *   使 MyKeymap 等同 MIDI 输入设备. 不依赖任何第三方 MIDI 库.
 *
 * 两种运行模式 (g_MidiMode):
 *   "winmm" — 系统里已存在目标端口 (例如 loopMIDI 持久端口), 用 winmm.midiOutShortMsg 发送.
 *   "tevm"  — 系统里没有目标端口, 用 teVirtualMIDI 在本进程内创建真实虚拟端口,
 *             必须用 teVirtualMIDI.virtualMIDISendData 发送 (实测: 进程内创建的端口
 *             若用 winmm.midiOut 写入, 数据只会进入创建进程自己的接收队列, 其他
 *             应用/DAW 收不到). 该端口生命周期与 MyKeymap 进程绑定, 退出即销毁.
 *
 * 对外函数:
 *   MidiInit(portName := "")                     初始化并打开输出端口 (缺失时自动创建)
 *   MidiEnsurePort(portName)                     内部: 用 teVirtualMIDI 创建虚拟端口
 *   MidiNoteOn(note, channel := 1, velocity := 100)  发送 NoteOn (按下发声)
 *   MidiNoteOff(note, channel := 1)              发送 NoteOff (松开停声)
 *   MidiAllNotesOff()                            对全部 16 通道发送 CC123, 防卡音
 *   MidiClose()                                  关闭端口 (自建端口一并销毁)
 *   MidiDebugPorts()                             仅调试: 返回所有输出端口名 (不主动调用)
 *
 * MIDI 通道名/编号映射:
 *   对外约定通道为 1–16 (与 midiOutGetDevCaps 的 wChannelMask 一致);
 *   winmm 消息字节低 4 位使用 0–15, 因此内部一律以 (channel - 1) 换算.
 *
 * MIDIOUTCAPS 结构体 (Unicode / 64 位, 4 字节对齐):
 *   偏移 0  WORD  wMid            2
 *   偏移 2  WORD  wPid            2
 *   偏移 4  UINT  vDriverVersion  4
 *   偏移 8  WCHAR szPname[32]     64   <- 端口名, 用 StrGet(ptr + 8, 32, "UTF-16") 读取
 *   偏移 72 WORD  wTechnology     2
 *   偏移 74 WORD  wVoices         2
 *   偏移 76 WORD  wNotes          2
 *   偏移 78 WORD  wChannelMask    2
 *   偏移 80 DWORD dwSupport       4
 *   合计 84 字节
 */

; ---- 模块级静态状态 (Super-global, 进程内共享, 保证只打开一次) ----
global g_MidiMode := "none"     ; "none" | "winmm" | "tevm"
global g_MidiHandle := 0        ; HMIDIOUT 输出句柄; 0 表示未打开 (winmm 模式)
global g_MidiDeviceID := -1     ; 当前已打开的 MIDI 设备号 (winmm 模式)
global g_MidiPortName := ""     ; 当前已打开/已创建的端口名
global g_MidiLastError := ""    ; 最近一次失败原因
global g_MidiCreatedPort := 0   ; teVirtualMIDI 端口句柄; 0 表示未创建 (tevm 模式)
global g_MidiDll := ""          ; 创建端口时使用的 teVirtualMIDI DLL 名

; ---- MIDIOUTCAPS 布局常量 ----
global MIDI_CAPS_SIZE := 84             ; 结构体总大小 (字节)
global MIDI_CAPS_PNAME_OFFSET := 8      ; szPname 的偏移 (字节)
global MIDI_CAPS_PNAME_CCH := 32        ; szPname 的 WCHAR 数

/**
 * 初始化 MIDI 输出.
 *  - 已打开/已创建时直接复用, 进程内只初始化一次.
 *  - 第一步: 枚举 winmm 输出设备, 严格匹配 portName (忽略大小写).
 *  - 第二步: 若无精确匹配, 用 teVirtualMIDI 创建同名虚拟端口并切换为 tevm 模式.
 *  - 第三步 (降级): 创建失败或环境不具备时, 回退到名字含 loopMIDI 的设备, 再退回 0 号设备.
 * 任何一步失败都不会抛错, 只会返回 false 并记录 g_MidiLastError.
 * @param portName 期望的端口名, 空字符串表示自动选择
 * @return true 表示已成功打开/创建; false 表示失败 (原因见 g_MidiLastError)
 */
MidiInit(portName := "") {
  ; AHK v2 中函数内一旦赋值即视为局部变量, 访问模块级静态状态必须显式 global
  global g_MidiMode, g_MidiHandle, g_MidiDeviceID, g_MidiPortName, g_MidiLastError, g_MidiCreatedPort, g_MidiDll
  ; 已就绪则复用
  if (g_MidiMode != "none") {
    return true
  }

  numDevs := DllCall("winmm\midiOutGetNumDevs", "UInt")
  matchExact := -1    ; 精确匹配 portName 的设备号
  matchLoop := -1     ; 名字含 loopMIDI 的设备号

  if (numDevs > 0) {
    caps := Buffer(MIDI_CAPS_SIZE, 0)
    i := 0
    while (i < numDevs) {
      res := DllCall("winmm\midiOutGetDevCapsW", "UPtr", i, "Ptr", caps, "UInt", MIDI_CAPS_SIZE, "UInt")
      if (res = 0) {
        name := StrGet(caps.Ptr + MIDI_CAPS_PNAME_OFFSET, MIDI_CAPS_PNAME_CCH, "UTF-16")
        ; 用 = 表示忽略大小写进行字符串比较
        if (portName != "" && name = portName) {
          matchExact := i
        }
        if (matchLoop = -1 && InStr(name, "loopMIDI", false)) {
          matchLoop := i
        }
      } else {
        OutputDebug("MidiInit: midiOutGetDevCapsW 失败, 设备 " i ", 错误码 " res)
      }
      i++
    }
  }

  ; 第一步: 精确匹配到目标端口, 沿用 winmm 发送
  if (matchExact != -1) {
    return MidiOpenWinmm(matchExact, portName)
  }

  ; 第二步: 目标端口不存在, 尝试用 teVirtualMIDI 创建 (仅当指定了端口名)
  if (portName != "") {
    hPort := MidiEnsurePort(portName)
    if (hPort) {
      g_MidiMode := "tevm"
      g_MidiCreatedPort := hPort
      g_MidiHandle := 0
      g_MidiDeviceID := MidiFindDeviceByName(portName)   ; 仅用于展示/调试, 可能为 -1
      g_MidiPortName := portName
      g_MidiLastError := ""
      OutputDebug("MidiInit: 已用 teVirtualMIDI 创建虚拟端口 '" portName "' (handle " hPort ")")
      return true
    }
    ; 创建失败: 记录原因, 继续走降级逻辑
    if (g_MidiLastError = "") {
      g_MidiLastError := "teVirtualMIDI 创建端口 '" portName "' 失败或无 teVirtualMIDI 驱动"
    }
    OutputDebug("MidiInit: " g_MidiLastError)
  }

  ; 第三步: 降级到 loopMIDI 设备或 0 号设备 (沿用 winmm 发送)
  if (matchLoop != -1) {
    OutputDebug("MidiInit: 退化使用 loopMIDI 设备 " matchLoop " ('" portName "' 不可用)")
    return MidiOpenWinmm(matchLoop, portName)
  }
  if (numDevs > 0) {
    OutputDebug("MidiInit: 退化使用 0 号输出设备 ('" portName "' 不可用)")
    return MidiOpenWinmm(0, portName)
  }

  g_MidiLastError := "未找到任何 MIDI 输出设备, 且无法创建虚拟端口"
  OutputDebug("MidiInit: " g_MidiLastError)
  return false
}

/**
 * 内部: 按设备号打开 winmm 输出端口并切换到 winmm 模式.
 * @param devID winmm 设备号
 * @param portName 记录用的端口名
 * @return true 表示打开成功
 */
MidiOpenWinmm(devID, portName) {
  global g_MidiMode, g_MidiHandle, g_MidiDeviceID, g_MidiPortName, g_MidiLastError
  hMidi := 0
  res := DllCall("winmm\midiOutOpen", "Ptr*", &hMidi, "UInt", devID, "Ptr", 0, "Ptr", 0, "UInt", 0, "UInt")
  if (res != 0) {   ; MMSYSERR_NOERROR = 0
    g_MidiLastError := "midiOutOpen 失败, 设备 " devID ", 错误码 " res
    OutputDebug("MidiInit: " g_MidiLastError)
    return false
  }
  g_MidiMode := "winmm"
  g_MidiHandle := hMidi
  g_MidiDeviceID := devID
  g_MidiPortName := portName
  g_MidiLastError := ""
  return true
}

/**
 * 内部: 枚举 winmm 输出设备, 返回精确匹配 name 的设备号 (忽略大小写); 无匹配返回 -1.
 */
MidiFindDeviceByName(name) {
  numDevs := DllCall("winmm\midiOutGetNumDevs", "UInt")
  caps := Buffer(MIDI_CAPS_SIZE, 0)
  i := 0
  while (i < numDevs) {
    if (DllCall("winmm\midiOutGetDevCapsW", "UPtr", i, "Ptr", caps, "UInt", MIDI_CAPS_SIZE, "UInt") = 0) {
      if (StrGet(caps.Ptr + MIDI_CAPS_PNAME_OFFSET, MIDI_CAPS_PNAME_CCH, "UTF-16") = name) {
        return i
      }
    }
    i++
  }
  return -1
}

/**
 * 内部: 用 teVirtualMIDI 在本进程内创建一个指定名字的真实虚拟 MIDI 端口.
 *  - 使用 virtualMIDICreatePortEx2; 回调传 NULL (发送方向不使用回调, 且实测
 *    AHK CallbackCreate 回调会被驱动从非 AHK 线程调用, 导致进程崩溃).
 *  - 依次尝试 64 位与 32 位 DLL, 任一缺失/创建失败都返回 0 (不抛错).
 *  - 端口名必须非空且唯一.
 * @param portName 端口名
 * @return 成功返回端口句柄 (非 0); 失败返回 0, 原因写入 g_MidiLastError
 */
MidiEnsurePort(portName) {
  global g_MidiLastError, g_MidiDll
  if (portName = "") {
    g_MidiLastError := "端口名为空, 无法创建"
    return 0
  }
  dllNames := ["teVirtualMIDI64", "teVirtualMIDI"]
  for dll in dllNames {
    hPort := 0
    try {
      hPort := DllCall(dll "\virtualMIDICreatePortEx2"
        , "Str", portName   ; name
        , "Ptr", 0          ; callback (NULL)
        , "Ptr", 0          ; instance
        , "UInt", 65536     ; maxSysex
        , "UInt", 0         ; flags
        , "UInt", 0         ; clientCount
        , "Ptr")            ; out: port handle
    } catch as e {
      g_MidiLastError := dll " 不可用: " e.Message
      continue
    }
    if (hPort && hPort != 0) {
      g_MidiDll := dll
      return hPort
    }
    g_MidiLastError := dll "\virtualMIDICreatePortEx2 返回 0 (端口名可能已被占用), LastError=" A_LastError
  }
  return 0
}

/**
 * 发送 NoteOn (按下发声).
 * dwMsg = (0x90 | ((channel-1) & 0x0F)) | (note << 8) | (velocity << 16)
 * @param note 音符号 0–127
 * @param channel MIDI 通道 1–16
 * @param velocity 力度 1–127
 * @return true 表示消息已提交; false 表示端口未打开或发送失败
 */
MidiNoteOn(note, channel := 1, velocity := 100) {
  if (!MidiReady()) {
    return false
  }
  ch := (channel - 1) & 0x0F
  msg := (0x90 | ch) | ((note & 0x7F) << 8) | ((velocity & 0x7F) << 16)
  return MidiSend(msg)
}

/**
 * 发送 NoteOff (松开停声).
 * dwMsg = (0x80 | ((channel-1) & 0x0F)) | (note << 8)
 * @param note 音符号 0–127
 * @param channel MIDI 通道 1–16
 * @return true 表示消息已提交; false 表示端口未打开或发送失败
 */
MidiNoteOff(note, channel := 1) {
  if (!MidiReady()) {
    return false
  }
  ch := (channel - 1) & 0x0F
  msg := (0x80 | ch) | ((note & 0x7F) << 8)
  return MidiSend(msg)
}

/**
 * 对全部 16 个通道发送 CC123 (All Notes Off), 用于退出/重载前防止残留发声.
 * dwMsg = (0xB0 | ((channel-1) & 0x0F)) | (123 << 8)
 * @return true 表示已尝试发送; false 表示端口未打开
 */
MidiAllNotesOff() {
  if (!MidiReady()) {
    return false
  }
  ch := 0
  while (ch < 16) {
    msg := (0xB0 | ch) | (123 << 8)
    MidiSend(msg)
    ch++
  }
  return true
}

/**
 * 内部: 当前是否已有可发送的端口 (winmm 句柄或 tevm 端口句柄).
 */
MidiReady() {
  global g_MidiMode, g_MidiHandle, g_MidiCreatedPort
  if (g_MidiMode = "tevm") {
    return g_MidiCreatedPort != 0
  }
  if (g_MidiMode = "winmm") {
    return g_MidiHandle != 0
  }
  return false
}

/**
 * 关闭 MIDI 输出端口并清空状态.
 *  - tevm 模式: 调用 virtualMIDIClosePort 销毁本进程创建的虚拟端口, 避免残留.
 *  - winmm 模式: 调用 midiOutClose 关闭句柄.
 * @return true 表示关闭成功或本就未打开; false 表示底层关闭失败
 */
MidiClose() {
  global g_MidiMode, g_MidiHandle, g_MidiDeviceID, g_MidiPortName, g_MidiLastError, g_MidiCreatedPort, g_MidiDll
  ok := true

  ; 先销毁自建虚拟端口
  ; 注: 实测 virtualMIDIClosePort 返回 0 即表示成功销毁, 失败会抛异常,
  ;     因此这里不依据返回值判定失败, 避免误报.
  if (g_MidiCreatedPort) {
    try {
      DllCall(g_MidiDll "\virtualMIDIClosePort", "Ptr", g_MidiCreatedPort, "UInt")
    } catch as e {
      g_MidiLastError := "virtualMIDIClosePort 异常: " e.Message
      OutputDebug("MidiClose: " g_MidiLastError)
      ok := false
    }
    g_MidiCreatedPort := 0
    g_MidiDll := ""
  }

  ; 再关闭 winmm 句柄
  if (g_MidiHandle) {
    res := DllCall("winmm\midiOutClose", "Ptr", g_MidiHandle, "UInt")
    if (res != 0) {
      g_MidiLastError := "midiOutClose 失败, 错误码 " res
      OutputDebug("MidiClose: " g_MidiLastError)
      ok := false
    }
  }

  g_MidiMode := "none"
  g_MidiHandle := 0
  g_MidiDeviceID := -1
  g_MidiPortName := ""
  return ok
}

/**
 * 内部: 发送一条已打包的 32 位 MIDI 短消息.
 *  - tevm 模式: 拆成 3 字节后用 virtualMIDISendData 推送给端口消费者.
 *  - winmm 模式: 用 winmm.midiOutShortMsg 发送.
 * @param dwMsg 32 位 MIDI 短消息
 * @return true 表示发送成功
 */
MidiSend(dwMsg) {
  global g_MidiMode, g_MidiHandle, g_MidiLastError, g_MidiCreatedPort, g_MidiDll
  if (!MidiReady()) {
    return false
  }

  if (g_MidiMode = "tevm") {
    buf := Buffer(3, 0)
    NumPut("UChar", dwMsg & 0xFF, buf, 0)
    NumPut("UChar", (dwMsg >> 8) & 0xFF, buf, 1)
    NumPut("UChar", (dwMsg >> 16) & 0xFF, buf, 2)
    try {
      r := DllCall(g_MidiDll "\virtualMIDISendData", "Ptr", g_MidiCreatedPort, "Ptr", buf, "UInt", 3, "Int")
    } catch as e {
      g_MidiLastError := "virtualMIDISendData 异常: " e.Message
      OutputDebug("MidiSend: " g_MidiLastError)
      return false
    }
    if (r = 0) {   ; 非 0 表示成功
      g_MidiLastError := "virtualMIDISendData 返回 0, LastError=" A_LastError
      return false
    }
    return true
  }

  if (!g_MidiHandle) {
    return false
  }
  res := DllCall("winmm\midiOutShortMsg", "Ptr", g_MidiHandle, "UInt", dwMsg, "UInt")
  if (res != 0) {
    g_MidiLastError := "midiOutShortMsg 失败, 错误码 " res
    return false
  }
  return true
}

/**
 * 仅调试用: 返回所有 MIDI 输出端口名的多行文本. 正常流程不会调用.
 */
MidiDebugPorts() {
  numDevs := DllCall("winmm\midiOutGetNumDevs", "UInt")
  caps := Buffer(MIDI_CAPS_SIZE, 0)
  out := "MIDI 输出设备数量: " numDevs "`n"
  i := 0
  while (i < numDevs) {
    res := DllCall("winmm\midiOutGetDevCapsW", "UPtr", i, "Ptr", caps, "UInt", MIDI_CAPS_SIZE, "UInt")
    if (res = 0) {
      name := StrGet(caps.Ptr + MIDI_CAPS_PNAME_OFFSET, MIDI_CAPS_PNAME_CCH, "UTF-16")
      out .= i ": " name "`n"
    } else {
      out .= i ": <读取失败, 错误码 " res ">`n"
    }
    i++
  }
  return out
}
