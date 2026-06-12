using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.Json.Nodes;
using Max.Core;

namespace Max.Windows.Platform;

/// <summary>
/// see_screen — captures the foreground window (or full screen) so Max can SEE the
/// display, the Windows analog of the macOS screencapture tool. Downscales + JPEGs
/// to keep token cost sane. No special permission needed on Windows.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ScreenCaptureTool : IMaxTool
{
    public ToolSpec Spec => new(
        "see_screen",
        "Take a screenshot so you can SEE what's on screen — layout, images, errors, whatever app is in front. " +
        "target \"window\" captures only the focused window (preferred); \"screen\" captures the full display.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["target"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("window", "screen") },
            },
            ["required"] = new JsonArray(),
        });

    public string Summary(JsonObject input) => $"looking at the {(string?)input["target"] ?? "window"}";

    public Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct)
    {
        try
        {
            var target = (string?)input["target"] ?? "window";
            Rectangle bounds;
            var title = "screen";

            if (target == "window")
            {
                var hwnd = GetForegroundWindow();
                if (hwnd != IntPtr.Zero && TryGetWindowBounds(hwnd, out bounds))
                    title = GetWindowTitle(hwnd);
                else
                    bounds = VirtualScreenBounds();
            }
            else bounds = VirtualScreenBounds();

            if (bounds.Width <= 0 || bounds.Height <= 0) bounds = VirtualScreenBounds();

            using var full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(full))
                g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);

            var payload = EncodeJpeg(full, maxEdge: 1500, quality: 70L);
            return Task.FromResult(ToolOutcome.WithImage(
                $"Screenshot of {title} ({DateTime.Now:T})", payload));
        }
        catch (Exception ex)
        {
            return Task.FromResult(ToolOutcome.Fail($"screenshot failed: {ex.Message}"));
        }
    }

    private static ImagePayload EncodeJpeg(Bitmap src, int maxEdge, long quality)
    {
        var scale = Math.Min(1.0, (double)maxEdge / Math.Max(src.Width, src.Height));
        var w = Math.Max(1, (int)(src.Width * scale));
        var h = Math.Max(1, (int)(src.Height * scale));
        using var resized = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(resized))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(src, 0, 0, w, h);
        }

        var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(Encoder.Quality, quality);
        using var ms = new MemoryStream();
        resized.Save(ms, codec, ep);
        return new ImagePayload(Convert.ToBase64String(ms.ToArray()), "image/jpeg");
    }

    private static Rectangle VirtualScreenBounds() =>
        new(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79));

    private static bool TryGetWindowBounds(IntPtr hwnd, out Rectangle rect)
    {
        // DWM extended frame bounds excludes the drop shadow; fall back to GetWindowRect.
        if (DwmGetWindowAttribute(hwnd, 9 /*DWMWA_EXTENDED_FRAME_BOUNDS*/, out var r, Marshal.SizeOf<RECT>()) == 0
            || GetWindowRect(hwnd, out r))
        {
            rect = new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
            return rect is { Width: > 0, Height: > 0 };
        }
        rect = Rectangle.Empty;
        return false;
    }

    private static string GetWindowTitle(IntPtr hwnd)
    {
        var len = GetWindowTextLength(hwnd);
        if (len == 0) return "window";
        var sb = new System.Text.StringBuilder(len + 1);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
}
