package script

import (
	"strings"
	"testing"
)

func TestSortActions(t *testing.T) {
	a := Action{WindowGroupID: 0, Comment: "item1"}
	b := Action{WindowGroupID: 1, Comment: "item2"}
	c := Action{WindowGroupID: 0, Comment: "item3"}
	s := []Action{a, b, c}
	ss := sortActions(s)
	assertEqual(t, ss[0], b)
	assertEqual(t, ss[1], a)
	assertEqual(t, ss[2], c)
}

func assertEqual[T comparable](t *testing.T, a, b T) {
	t.Helper()
	if a != b {
		t.Errorf("%v != %v", a, b)
	}
}

// 拖拽动作(ValueID 17/18)采用「单线程手势」模型: 只注册 down 一条(不再有 " up"),
// 且热键名**必须原样使用**——不得添加 "*" 通配符。
//
// 说明: "*" 只影响"忽略修饰键", 与拦截/不漏键无关; 擅自添加会扩大用户配置的
// 触发条件(按住 Win/Alt 也会触发), 属于隐式语义变更。详见 plans/bugfix-drag-midi.md。
func TestWindowActions3DragSingleThread(t *testing.T) {
	Cfg = &Config{}
	cases := map[int]string{
		17: "StartDragMoveWindow()",
		18: `StartDragResizeWindow("axis")`,
	}
	for valueID, call := range cases {
		out := windowActions3(Action{TypeID: 3, ValueID: valueID, Hotkey: "XButton2"}, false)
		// 必须保留用户原热键名(不加 *)
		if !strings.Contains(out, `km.Map("XButton2",`) {
			t.Errorf("valueID %d: expected original hotkey name without '*': %s", valueID, out)
		}
		if strings.Contains(out, "*XButton2") {
			t.Errorf("valueID %d: must not add '*' wildcard: %s", valueID, out)
		}
		// 必须只注册 down (单线程手势), 不再注册 " up"
		if strings.Contains(out, `"XButton2 up"`) {
			t.Errorf("valueID %d: must not register an 'up' hotkey (single-thread model): %s", valueID, out)
		}
		// 必须调用对应的拖拽起始函数
		if !strings.Contains(out, call) {
			t.Errorf("valueID %d: expected call %q: %s", valueID, call, out)
		}
	}
}
