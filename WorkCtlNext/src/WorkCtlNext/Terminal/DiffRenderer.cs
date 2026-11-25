using System.Diagnostics;
using System.Text;

namespace WorkCtlNext.Terminal;

/// <summary>
/// Line-differential VT renderer wrapped in synchronized output (?2026h/l) and DECAWM (?7l/h)
/// auto-wrap suppression to prevent last-column corner scroll and selection background bleed.
/// </summary>
public sealed class DiffRenderer
{
    private readonly ITerminalBackend _backend;
    private string[] _prevLines = [];
    private int _prevWidth = -1;
    private int _prevHeight = -1;

    public long FramesRendered { get; private set; }
    public long SkippedNoOpFrames { get; private set; }
    public double LastRenderMs { get; private set; }

    public DiffRenderer(ITerminalBackend backend)
    {
        _backend = backend ?? throw new ArgumentNullException(nameof(backend));
    }

    public void Invalidate()
    {
        _prevLines = [];
        _prevWidth = -1;
        _prevHeight = -1;
    }

    public void Render(IReadOnlyList<string> rawLines)
    {
        long startTick = Stopwatch.GetTimestamp();
        int width = Math.Max(20, _backend.WindowWidth);
        int height = Math.Max(8, _backend.WindowHeight);
        bool resized = width != _prevWidth || height != _prevHeight;

        var frame = new string[height];
        for (int row = 0; row < height; row++)
        {
            string line = row < rawLines.Count ? rawLines[row] ?? string.Empty : string.Empty;
            frame[row] = ClampAndPad(line, width);
        }

        if (!resized && _prevLines.Length == height)
        {
            bool anyChanged = false;
            for (int r = 0; r < height; r++)
            {
                if (!string.Equals(_prevLines[r], frame[r], StringComparison.Ordinal))
                {
                    anyChanged = true;
                    break;
                }
            }
            if (!anyChanged)
            {
                SkippedNoOpFrames++;
                LastRenderMs = Stopwatch.GetElapsedTime(startTick).TotalMilliseconds;
                return;
            }
        }

        var sb = new StringBuilder(2048);
        sb.Append("\u001b[?2026h\u001b[?7l");
        if (resized)
        {
            sb.Append("\u001b[2J\u001b[H");
        }

        for (int row = 0; row < height; row++)
        {
            if (!resized && row < _prevLines.Length && string.Equals(_prevLines[row], frame[row], StringComparison.Ordinal))
                continue;

            sb.Append("\u001b[").Append(row + 1).Append(";1H");
            sb.Append(frame[row]);
        }

        sb.Append("\u001b[?7h\u001b[?2026l");
        _backend.Write(sb.ToString());
        _backend.Flush();

        _prevLines = frame;
        _prevWidth = width;
        _prevHeight = height;
        FramesRendered++;
        LastRenderMs = Stopwatch.GetElapsedTime(startTick).TotalMilliseconds;
    }

    public static int MeasureVisibleLength(string input)
    {
        if (string.IsNullOrEmpty(input)) return 0;
        int visible = 0;
        bool inEsc = false;

        foreach (Rune r in input.EnumerateRunes())
        {
            int val = r.Value;
            if (val == 0x1B) { inEsc = true; continue; }
            if (inEsc)
            {
                if (val is >= '@' and <= '~' && val != '[') inEsc = false;
                continue;
            }
            if (val is '\r' or '\n' or '\t') { visible++; continue; }
            if (Rune.IsControl(r)) continue;
            visible++;
        }
        return visible;
    }

    /// <summary>
    /// Truncates or pads a styled ANSI string to an exact visible cell width while terminating
    /// background SGR attributes cleanly before trailing spaces unless trailingBg is provided.
    /// </summary>
    public static string ClampAndPad(string input, int width)
        => PadVisible(input, width, resetBeforeFill: true);

    public static string PadVisible(string input, int width, bool resetBeforeFill = true)
    {
        if (width <= 0) return string.Empty;

        var visible = new StringBuilder(width + 24);
        bool inEscape = false;
        bool sawEscape = false;
        int visibleCount = 0;

        foreach (Rune rune in (input ?? string.Empty).EnumerateRunes())
        {
            int val = rune.Value;
            if (val == 0x1B)
            {
                inEscape = true;
                sawEscape = true;
                visible.Append('\u001b');
                continue;
            }
            if (inEscape)
            {
                visible.Append(rune);
                if (val is >= '@' and <= '~' && val != '[')
                    inEscape = false;
                continue;
            }
            if (val is '\r' or '\n' or '\t')
            {
                if (visibleCount < width)
                {
                    visible.Append(' ');
                    visibleCount++;
                }
                continue;
            }
            if (Rune.IsControl(rune))
                continue;

            if (visibleCount >= width)
                break;

            visible.Append(rune);
            visibleCount++;
        }

        if (sawEscape && resetBeforeFill && visibleCount < width)
            visible.Append("\u001b[0m");

        if (visibleCount < width)
            visible.Append(' ', width - visibleCount);

        return sawEscape ? visible.ToString() + "\u001b[0m" : visible.ToString();
    }
}