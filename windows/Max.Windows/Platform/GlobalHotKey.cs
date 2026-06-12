using System.Runtime.InteropServices;

namespace Max.Windows.Platform;

/// <summary>
/// System-wide summon hotkey (default Alt+Space), the Windows analog of the macOS
/// Carbon RegisterEventHotKey. Runs a hidden message-only window on its own thread
/// and invokes <see cref="Pressed"/> on WM_HOTKEY. Modifiers/VK come from MaxConfig.
/// </summary>
public sealed class GlobalHotKey : IDisposable
{
    public event Action? Pressed;

    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 0xB00B;
    private Thread? _thread;
    private IntPtr _hwnd;
    private volatile bool _running;
    private readonly uint _modifiers;
    private readonly uint _vk;

    public GlobalHotKey(uint modifiers, uint vk) { _modifiers = modifiers; _vk = vk; }

    public void Start()
    {
        _running = true;
        _thread = new Thread(MessageLoop) { IsBackground = true, Name = "MaxHotKey" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    private void MessageLoop()
    {
        // Message-only window (HWND_MESSAGE parent) — no UI, just a WndProc.
        var wndProc = new WndProcDelegate(WndProc);
        var cls = new WNDCLASS { lpszClassName = "MaxHotKeyWnd", lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc) };
        RegisterClass(ref cls);
        _hwnd = CreateWindowEx(0, cls.lpszClassName, "", 0, 0, 0, 0, 0, new IntPtr(-3) /*HWND_MESSAGE*/, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        if (!RegisterHotKey(_hwnd, HOTKEY_ID, _modifiers, _vk))
            System.Diagnostics.Debug.WriteLine($"RegisterHotKey failed: {Marshal.GetLastWin32Error()}");

        while (_running && GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
        GC.KeepAlive(wndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HOTKEY_ID)
            Pressed?.Invoke();
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        _running = false;
        if (_hwnd != IntPtr.Zero)
        {
            UnregisterHotKey(_hwnd, HOTKEY_ID);
            PostMessage(_hwnd, 0x0012 /*WM_QUIT*/, IntPtr.Zero, IntPtr.Zero);
        }
    }

    private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASS
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int pt_x; public int pt_y;
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern ushort RegisterClass(ref WNDCLASS lpWndClass);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
