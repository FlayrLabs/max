using System.Runtime.Versioning;
using Max.Core;

namespace Max.Windows.Platform;

/// <summary>
/// Assembles the tool set for the Windows app: Core base tools (exec, read/write file,
/// loop) plus the Windows-native tools (app control, screen vision). Shared by the pill,
/// channels, and loops so capabilities stay consistent.
/// </summary>
[SupportedOSPlatform("windows")]
public static class WindowsToolset
{
    /// <summary>For the desk pill and channels: full capabilities (screen vision per config).</summary>
    public static IReadOnlyList<IMaxTool> ForInteractive(MaxConfig config)
    {
        var tools = AgentLoop.BaseTools(config);
        tools.Add(new AppControlTool(config));
        if (config.AllowScreenVision)
        {
            tools.Add(new ScreenCaptureTool());
            tools.Add(new ReadScreenTextTool());
        }
        return tools;
    }

    /// <summary>For loops: blind by default — screen tools only if the user opted in.</summary>
    public static IReadOnlyList<IMaxTool> ForLoop(MaxConfig config)
    {
        var tools = AgentLoop.BaseTools(config);
        tools.Add(new AppControlTool(config));
        if (config.AllowScreenVision && config.LoopsCanSeeScreen)
        {
            tools.Add(new ScreenCaptureTool());
            tools.Add(new ReadScreenTextTool());
        }
        return tools;
    }
}
