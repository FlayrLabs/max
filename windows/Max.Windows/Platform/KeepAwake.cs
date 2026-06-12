using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Max.Windows.Platform;

/// <summary>
/// Keeps the PC awake so loops/channels keep working while you're away — the Windows
/// analog of macOS `caffeinate`. Call <see cref="Apply"/> on a long-lived thread
/// (the UI thread); the flag persists until reset.
/// </summary>
[SupportedOSPlatform("windows")]
public static class KeepAwake
{
    [Flags]
    private enum ExecutionState : uint
    {
        Continuous = 0x80000000,
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002,
    }

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(ExecutionState esFlags);

    public static void Apply(bool keepAwake)
    {
        // SYSTEM_REQUIRED prevents idle sleep; we deliberately do NOT set DISPLAY_REQUIRED
        // so the screen can still turn off. CONTINUOUS makes it sticky.
        SetThreadExecutionState(keepAwake
            ? ExecutionState.Continuous | ExecutionState.SystemRequired
            : ExecutionState.Continuous);
    }
}
