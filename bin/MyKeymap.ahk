#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true

#include lib/translation.ahk
#Include lib/Functions.ahk
#Include lib/Actions.ahk
#Include lib/KeymapManager.ahk
#Include lib/InputTipWindow.ahk
#Include lib/Utils.ahk
#Include lib/Midi.ahk

; #WinActivateForce   ; 先关了遇到相关问题再打开试试
; InstallKeybdHook    ; 这个可以重装 keyboard hook, 提高自己的 hook 优先级, 以后可能会用到
; ListLines False     ; 也许能提升一点点性能 ( 别抱期待 ), 当有这个需求时再打开试试
; #Warn All, Off      ; 也许能提升一点点性能 ( 别抱期待 ), 当有这个需求时再打开试试

try DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr") ; 多显示器不同缩放比例会导致问题: https://www.autohotkey.com/boards/viewtopic.php?f=14&t=13810
SetMouseDelay 0                                           ; SendInput 可能会降级为 SendEvent, 此时会有 10ms 的默认 delay
SetWinDelay 0                                             ; 默认会在 activate, maximize, move 等窗口操作后睡眠 100ms
A_MaxHotkeysPerInterval := 256                            ; 默认 70 可能有点低, 即使没有热键死循环也触发警告
SendMode "Event"                                          ; 执行 SendInput 的期间会短暂卸载 Hook, 这时候松开引导键会丢失 up 事件, 所以 Event 模式更适合 MyKeymap
SetKeyDelay 0                                             ; 默认 10 太慢了, https://www.reddit.com/r/AutoHotkey/comments/gd3z4o/possible_unreliable_detection_of_the_keyup_event/
ProcessSetPriority "High"
SetWorkingDir("../")
InitTrayMenu()
InitKeymap()
OnExit(MyKeymapExit)
#include ../data/custom_functions.ahk

InitKeymap()
{
  ; 端口不存在时 MIDI 动作不生效, 提示用户去 loopMIDI 创建 (不自动创建/不回退)
  if !MidiInit("loopMIDI Port") {
    MidiShowNotReadyTip()
  }
  taskSwitch := TaskSwitchKeymap("e", "d", "s", "f", "c", "space")
  mouseTip := false
  slow := MouseKeymap("slow mouse", false, mouseTip, 10, 13, "T0.13", "T0.01", 1, "T0.2", "T0.03")
  fast := MouseKeymap("fast mouse", false, mouseTip, 110, 70, "T0.13", "T0.01", 1, "T0.2", "T0.03", slow)
  slow.Map("*space", slow.LButtonUp())


  ; 路径变量
  programs := "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\"

  ; 窗口组
  GroupAdd("MY_WINDOW_GROUP_1", "ahk_exe chrome.exe")
  GroupAdd("MY_WINDOW_GROUP_1", "ahk_exe msedge.exe")
  GroupAdd("MY_WINDOW_GROUP_1", "ahk_exe firefox.exe")

  KeymapManager.GlobalKeymap.DisabledAt := ""

  ; CapsLock
  km5 := KeymapManager.NewKeymap("*CapsLock", "CapsLock", "", "")
  km := km5
  km.Map("*t", _ => ActivateOrRun("powershell.exe", "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "", "", true, true, false))
  km.Map("*c", _ => CopySelectedAsPlainText())
  km.Map("*v", _ => ShowActiveProcessInFolder())
  km.Map("*b", _ => ToggleWindowTopMost())
  km.Map("*space", _ => CloseWindowProcesses())
  km.RemapKey("e", "]")
  km.RemapKey("q", "[")
  km.Map("*1", _ => (Send("^!o")))
  km.Map("*3", _ => (Send("^!p")))
  km.Map("singlePress", _ => (Send("{blind}{CapsLock}")))
  km.Map("*g", _ => MyKeymapOpenSettings())

  ; Alt模式
  km6 := KeymapManager.NewKeymap("customHotkeys", "Alt模式", "", "")
  km := km6
  km.Map("*!*1", _ => ActivateOrRun("EverEdit ahk_class EverEdit", "M:\01_Program\ProgramMaye\EverEdit-4.5.0.4500-x64\EverEdit.exe", "", "", false, true, false))
  km.Map("*!*2", _ => ActivateOrRun("XYplorer ahk_class ThunderRT6FormDC", "M:\01_Program\ProgramMaye\XYplorer-24.60.0100\XYplorer.exe", "", "", true, true, false))
  km.Map("*!*3", _ => ActivateOrRun("ahk_exe Obsidian.exe", "M:\01_Program\ProgramMaye\obsidian\ObsidianPortable.exe", "", "M:\01_Program\ProgramMaye\obsidian", false, true, false))
  km.Map("*!*4", _ => ActivateOrRun(" Google Chrome ahk_exe chrome.exe", "M:\01_Program\ProgramMaye\ChromeProtable\Chrome\App\chrome.exe", "", "", false, true, false))
  km.Map("*!*q", _ => ActivateOrRun("ahk_exe project-graph.exe", "M:\01_Program\ProgramMaye\project-graph\project-graph.exe", "", "", false, true, false))
  km.Map("*!*w", _ => ActivateOrRun("ahk_class MozillaWindowClass", "M:\01_Program\ProgramMaye\firefox\firefox-144.0.2-2025102712.en-US.win32-tete009-x64-sse3-cspgo\firefox.exe", "", "", false, true, false))

  ; Tab 模式
  km11 := KeymapManager.NewKeymap("Tab", "Tab 模式", "", "")
  km := km11
  km.Map("*f", _ => MakeWindowDraggable())
  km.Map("*,", _ => MoveMouseToCaret()), slow.Map("*,", _ => MoveMouseToCaret())
  km.Map("*2", fast.ScrollWheelUp), slow.Map("*2", slow.ScrollWheelUp)
  km.Map("*i", fast.MoveMouseUp, slow), slow.Map("*i", slow.MoveMouseUp)
  km.Map("*j", fast.MoveMouseLeft, slow), slow.Map("*j", slow.MoveMouseLeft)
  km.Map("*k", fast.MoveMouseDown, slow), slow.Map("*k", slow.MoveMouseDown)
  km.Map("*l", fast.MoveMouseRight, slow), slow.Map("*l", slow.MoveMouseRight)
  km.Map("*o", fast.RButton()), slow.Map("*o", slow.RButton())
  km.Map("*u", fast.LButton()), slow.Map("*u", slow.LButton())
  km.Map("*w", fast.ScrollWheelDown), slow.Map("*w", slow.ScrollWheelDown)
  km.Map("*4", _ => (Send("!+4")))
  km.Map("*a", _ => (Send("{Ctrl down}{WheelUp}{WheelUp}{WheelUp}{WheelUp}{WheelUp}{Ctrl up}")))
  km.Map("*c", _ => (Send("!+c")))
  km.Map("*r", _ => (Send("!+r")))
  km.Map("*s", _ => (Send("!+d")))
  km.Map("*x", _ => (Send("!+x")))
  km.Map("*z", _ => (Send("{Ctrl down}{WheelDown}{WheelDown}{WheelDown}{WheelDown}{WheelDown}{Ctrl up}")))
  km.Map("*space", _ => (Send("^+{space}")))
  km.Map("singlePress", _ => (Send("{tab}")))
  km.Map("*1", _ => (Send("^+{tab}")))
  km.Map("*3", _ => (Send("^{tab}")))
  km.RemapKey("d", "delete")
  km.Map("*e", _ => (Send("{blind}{enter}")))
  km.RemapKey("q", "backspace")
  km.Map("*t", _ => sendCurrentDateTime())

  ; 波浪
  km20 := KeymapManager.NewKeymap("*``", "波浪", "", "")
  km := km20
  km.Map("*1", _ => ActivateOrRun("ahk_exe lx-music-desktop.exe", "M:\01_Program\ProgramMaye\lx-music\LxMusic2.12.3\lx-music-desktop_Portable.exe", "", "M:\01_Program\ProgramMaye\lx-music\LxMusic2.12.3", false, true, false))
  km.Map("*2", _ => ActivateOrRun("Mihomo Party ahk_exe Mihomo Party.exe", "M:\01_Program\ProgramMaye\mihomo-party-windows\mihomo-party-windows-1.8.2-x64-portable\Mihomo Party.exe", "", "", false, true, true))
  km.Map("*3", _ => ActivateOrRun("任务管理器 ahk_exe Taskmgr.exe", "C:\Windows\System32\Taskmgr.exe", "", "", false, true, false))
  km.Map("*4", _ => ActivateOrRun("CareUEyes ahk_class SOUIHOST", "M:\01_Program\ProgramMaye\CareUEyes\CareUEyesPortable.exe", "", "M:\01_Program\ProgramMaye\CareUEyes", false, true, false))
  km.Map("*a", _ => ActivateOrRun("ahk_exe SndVol.exe", "C:\Windows\System32\SndVol.exe", "", "", false, true, false))
  km.Map("*c", _ => ActivateOrRun("ahk_class Qt683QWindowIcon ahk_exe obs64.exe", "M:\01_Program\ProgramMaye\obs-studio\OBS-Studio-32.1.2-Windows-x64\bin\64bit\obs64Portable.exe", "", "M:\01_Program\ProgramMaye\obs-studio\OBS-Studio-32.1.2-Windows-x64\bin\64bit", true, true, false))
  km.Map("*m", _ => ActivateOrRun("ahk_exe osk.exe", "shortcuts\On-Screen Keyboard.lnk", "", "", false, true, false))
  km.Map("*q", _ => ActivateOrRun("ahk_exe SteelSeriesGGClient.exe", "C:\Program Files\SteelSeries\GG\SteelSeries GG Launcher.lnk", "", "", false, true, false))
  km.Map("*x", _ => ActivateOrRun("ahk_exe bdcam.exe", "M:\01_Program\ProgramMaye\Bandicam\Bandicam-8.3.1.2537-x64-Portable\Bandicam\BandicamPortable.exe", "", "M:\01_Program\ProgramMaye\Bandicam\Bandicam-8.3.1.2537-x64-Portable\Bandicam", true, true, false))
  km.Map("*z", _ => ActivateOrRun("PixPin 配置 ahk_class Qt51513QWindowIcon ahk_exe PixPin.exe", "M:\01_Program\ProgramMaye\PixPin\Pixpin\PixPin.exe", "", "M:\01_Program\ProgramMaye\PixPin\Pixpin", true, true, false))
  km.Map("singlePress", _ => Send("^!{tab}"), taskSwitch)
  km.Map("*'", _ => (Send("{blind}{``}")))

  ; F1
  km31 := KeymapManager.NewKeymap("F1", "F1", "", "")
  km := km31
  km.Map("*/", _ => (Send("{F12}")))
  km.Map("singlePress", _ => (Send("{blind}{F1}")))
  km.MapMidi("*,", 94, 1, 100)
  km.MapMidi("*.", 95, 1, 100)
  km.MapMidi("*1", 61, 1, 100)
  km.MapMidi("*2", 63, 1, 100)
  km.MapMidi("*3", 68, 1, 100)
  km.MapMidi("*4", 73, 1, 100)
  km.MapMidi("*5", 75, 1, 100)
  km.MapMidi("*6", 80, 1, 100)
  km.MapMidi("*7", 85, 1, 100)
  km.MapMidi("*8", 87, 1, 100)
  km.MapMidi("*9", 92, 1, 100)
  km.MapMidi("*a", 62, 1, 100)
  km.MapMidi("*b", 82, 1, 100)
  km.MapMidi("*c", 71, 1, 100)
  km.MapMidi("*d", 69, 1, 100)
  km.MapMidi("*e", 67, 1, 100)
  km.MapMidi("*f", 74, 1, 100)
  km.MapMidi("*g", 77, 1, 100)
  km.MapMidi("*h", 81, 1, 100)
  km.MapMidi("*i", 88, 1, 100)
  km.MapMidi("*j", 86, 1, 100)
  km.MapMidi("*k", 89, 1, 100)
  km.MapMidi("*l", 93, 1, 100)
  km.MapMidi("*m", 90, 1, 100)
  km.MapMidi("*n", 83, 1, 100)
  km.MapMidi("*o", 91, 1, 100)
  km.MapMidi("*q", 60, 1, 100)
  km.MapMidi("*r", 72, 1, 100)
  km.MapMidi("*s", 65, 1, 100)
  km.MapMidi("*t", 76, 1, 100)
  km.MapMidi("*u", 84, 1, 100)
  km.MapMidi("*v", 78, 1, 100)
  km.MapMidi("*w", 64, 1, 100)
  km.MapMidi("*x", 70, 1, 100)
  km.MapMidi("*y", 79, 1, 100)
  km.MapMidi("*z", 66, 1, 100)

  ; F2
  km32 := KeymapManager.NewKeymap("F2", "F2", "", "")
  km := km32
  km.Map("*1", _ => (Send("{Pause}")))
  km.Map("*3", _ => (Send("{End}")))
  km.Map("singlePress", _ => (Send("{blind}{F2}")))

  ; Custom Hotkeys
  km1 := KeymapManager.NewKeymap("customHotkeys", "Custom Hotkeys", "", "")
  km := km1
  km.RemapInHotIf("F3", "F9")
  km.RemapInHotIf("F4", "F10")
  km.RemapInHotIf("PgUp", "End")
  km.RemapInHotIf("RAlt", "RWin")
  km.Map("!``", _ => MyKeymapToggleSuspend(), , , , "S")
  km.Map("!f17", _ => MyKeymapReload(), , , , "S")
  km.Map("^!``", _ => MyKeymapReload(), , , , "S")


  KeymapManager.GlobalKeymap.Enable()
}

ExecCapslockAbbr(command) {
}

ExecSemicolonAbbr(command) {
}

InitTrayMenu() {
  A_TrayMenu.Delete()
  A_TrayMenu.Add(Translation().menu_pause, TrayMenuHandler)
  A_TrayMenu.Add(Translation().menu_exit, TrayMenuHandler)
  A_TrayMenu.Add(Translation().menu_reload, TrayMenuHandler)
  A_TrayMenu.Add(Translation().menu_settings, TrayMenuHandler)
  A_TrayMenu.Add(Translation().menu_window_spy, TrayMenuHandler)
  A_TrayMenu.Default := Translation().menu_pause
  A_TrayMenu.ClickCount := 1

  A_IconTip := "MyKeymap 2.0-beta33 created by 咸鱼阿康"
  TraySetIcon("./bin/icons/logo.ico", , true)
}


#HotIf
PgUp::End
RAlt::RWin
F3::F9
F4::F10

#HotIf