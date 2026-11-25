namespace WorkCtlNext.Terminal;

/// <summary>
/// Pure terminal layout and formatting helpers: elevated header/surface painting,
/// split-pane gutter composition with SGR background isolation, scrollbar tracks,
/// and responsive metric shedding.
/// </summary>
public static class LayoutEngine
{
    public static List<string> ComposeColumns(
        IReadOnlyList<string> leftLines,
        int leftWidth,
        IReadOnlyList<string> rightLines,
        int rightWidth,
        int height,
        DesignTheme theme)
    {
        var result = new List<string>(height);
        string divider = theme.Style(theme.Border, $" {theme.RuleV} ");

        for (int i = 0; i < height; i++)
        {
            string lRaw = i < leftLines.Count ? leftLines[i] : string.Empty;
            string rRaw = i < rightLines.Count ? rightLines[i] : string.Empty;

            // resetBeforeFill:false inside each pane lets row selection BG span the column cleanly,
            // while PadVisible's trailing \u001b[0m stops BG before the hairline divider.
            string lCell = DiffRenderer.PadVisible(lRaw, leftWidth, resetBeforeFill: false);
            string rCell = DiffRenderer.PadVisible(rRaw, rightWidth, resetBeforeFill: false);
            result.Add(lCell + divider + rCell);
        }

        return result;
    }

    public static string PaintSurfaceRow(string content, int width, DesignTheme theme, string bgSgr)
    {
        if (theme.NoColor || string.IsNullOrEmpty(bgSgr))
            return DiffRenderer.PadVisible(content, width);

        string patched = bgSgr + content.Replace(theme.Reset, theme.Reset + bgSgr, StringComparison.Ordinal);
        return DiffRenderer.PadVisible(patched, width, resetBeforeFill: false);
    }

    public static string ComposeHeaderLine(
        int width,
        DesignTheme theme,
        string contextLabel,
        IReadOnlyList<string> rightParts)
    {
        string brand = $"{theme.Bold}{theme.Accent} WorkCtl Next{theme.Reset}";
        string sep = theme.Style(theme.Border, $" {theme.MiddleDot} ");
        int minLeft = DiffRenderer.MeasureVisibleLength(brand) + 3 + Math.Min(contextLabel.Length, 12);

        // Progressively shed lower-priority trailing pills instead of hiding all metrics abruptly.
        var active = rightParts.ToList();
        string rightJoined = JoinHeaderParts(active, theme);
        while (active.Count > 0 && minLeft + DiffRenderer.MeasureVisibleLength(rightJoined) + 2 > width)
        {
            active.RemoveAt(active.Count - 1);
            rightJoined = JoinHeaderParts(active, theme);
        }

        int rightLen = DiffRenderer.MeasureVisibleLength(rightJoined);
        int maxContext = Math.Max(8, width - DiffRenderer.MeasureVisibleLength(brand) - 3 - rightLen - 3);
        string trimmedCtx = DesignTheme.TruncateMiddle(contextLabel, maxContext);
        string left = $"{brand}{sep}{theme.Style(theme.Primary, trimmedCtx)}";

        int leftLen = DiffRenderer.MeasureVisibleLength(left);
        int gap = width - leftLen - rightLen - 1;
        string raw = gap >= 1 && rightLen > 0
            ? left + new string(' ', gap) + rightJoined + " "
            : left;

        return PaintSurfaceRow(raw, width, theme, theme.HeaderBarBg);
    }

    private static string JoinHeaderParts(IReadOnlyList<string> parts, DesignTheme theme)
    {
        if (parts.Count == 0) return string.Empty;
        string sep = theme.Style(theme.Border, $" {theme.MiddleDot} ");
        return string.Join(sep, parts);
    }

    public static string FormatKeyHint(DesignTheme theme, string key, string label)
        => $"{theme.Style(theme.Accent, key)} {theme.Style(theme.Secondary, label)}";

    public static string FormatKeyHintAligned(DesignTheme theme, string key, string description, int keyColWidth = 15)
    {
        string paddedKey = key.Length >= keyColWidth ? key : key.PadRight(keyColWidth);
        return $"{theme.Style(theme.Accent, paddedKey)} {theme.Style(theme.Secondary, description)}";
    }

    public static string FormatKeyValueRow(
        DesignTheme theme,
        string label,
        string styledValue,
        int labelWidth = 9)
    {
        string paddedLabel = label.Length >= labelWidth ? label : label.PadRight(labelWidth);
        return $" {theme.Style(theme.Secondary, paddedLabel)} {styledValue}";
    }

    public static string ScrollbarGlyph(DesignTheme theme, int row, int visibleRows, int totalItems, int scrollOffset)
    {
        if (totalItems <= visibleRows || visibleRows <= 0)
            return " ";

        int thumbSize = Math.Max(1, (int)Math.Round(visibleRows * (visibleRows / (double)totalItems)));
        thumbSize = Math.Min(visibleRows, thumbSize);
        int maxScroll = Math.Max(1, totalItems - visibleRows);
        int maxThumbTop = Math.Max(0, visibleRows - thumbSize);
        int thumbTop = (int)Math.Round((scrollOffset / (double)maxScroll) * maxThumbTop);
        bool isThumb = row >= thumbTop && row < thumbTop + thumbSize;
        return isThumb
            ? theme.Style(theme.Accent, theme.ScrollThumb)
            : theme.Style(theme.Border, theme.ScrollTrack);
    }

    public static IReadOnlyList<string> BuildErrorBox(
        DesignTheme theme,
        string headline,
        string? detail,
        int maxWidth)
    {
        var lines = new List<string>
        {
            $" {theme.Style(theme.Error, $"{theme.IconErr} {headline}")}"
        };
        if (!string.IsNullOrWhiteSpace(detail))
        {
            foreach (string wrapped in DesignTheme.WrapText(detail, Math.Max(20, maxWidth - 4), theme.AsciiOnly))
            {
                lines.Add($"   {theme.Style(theme.Secondary, wrapped)}");
            }
        }
        return lines;
    }

    public static string AlignLeftRight(string leftStyled, string rightStyled, int totalWidth)
    {
        int lw = DiffRenderer.MeasureVisibleLength(leftStyled);
        int rw = DiffRenderer.MeasureVisibleLength(rightStyled);
        if (lw + rw + 1 <= totalWidth)
            return leftStyled + new string(' ', totalWidth - lw - rw) + rightStyled;

        int maxLeft = Math.Max(4, totalWidth - rw - 1);
        string clampedLeft = DiffRenderer.PadVisible(leftStyled, maxLeft, resetBeforeFill: false);
        int clw = DiffRenderer.MeasureVisibleLength(clampedLeft);
        int gap = Math.Max(1, totalWidth - clw - rw);
        return clampedLeft + new string(' ', gap) + rightStyled;
    }

    public static void OverlayBox(
        List<string> canvas,
        int canvasWidth,
        int startRow,
        int startCol,
        int boxWidth,
        IReadOnlyList<string> innerRows,
        string title,
        DesignTheme theme,
        string? borderColor = null)
    {
        if (canvasWidth < 20 || canvas.Count < 4 || innerRows.Count == 0)
            return;

        int w = Math.Clamp(boxWidth, 20, canvasWidth);
        int c = Math.Clamp(startCol, 0, Math.Max(0, canvasWidth - w));
        int totalBoxRows = innerRows.Count + 2;
        int r0 = Math.Clamp(startRow, 0, Math.Max(0, canvas.Count - totalBoxRows));

        string bCol = borderColor ?? theme.Border;
        string tl = theme.AsciiOnly ? "+" : "┌";
        string tr = theme.AsciiOnly ? "+" : "┐";
        string bl = theme.AsciiOnly ? "+" : "└";
        string br = theme.AsciiOnly ? "+" : "┘";
        string h = theme.RuleH;
        string v = theme.RuleV;

        string cleanTitle = string.IsNullOrWhiteSpace(title)
            ? string.Empty
            : " " + DesignTheme.TruncateEnd(title, Math.Max(6, w - 6), theme.AsciiOnly) + " ";
        int fillTop = Math.Max(0, w - 2 - cleanTitle.Length);
        string topBorder = theme.Style(bCol, tl)
            + theme.Style(theme.Bold + theme.Accent, cleanTitle)
            + theme.Style(bCol, new string(h[0], fillTop) + tr);
        string bottomBorder = theme.Style(bCol, bl + new string(h[0], Math.Max(0, w - 2)) + br);

        var boxLines = new List<string>(totalBoxRows) { topBorder };
        int innerW = Math.Max(4, w - 2);
        foreach (string row in innerRows)
        {
            string padded = PaintSurfaceRow(row, innerW, theme, theme.CommandBarBg);
            boxLines.Add(theme.Style(bCol, v) + padded + theme.Style(bCol, v));
        }
        boxLines.Add(bottomBorder);

        for (int i = 0; i < boxLines.Count && (r0 + i) < canvas.Count; i++)
        {
            int targetIdx = r0 + i;
            if (c == 0 && w >= canvasWidth)
            {
                canvas[targetIdx] = DiffRenderer.ClampAndPad(boxLines[i], canvasWidth);
            }
            else
            {
                string existing = canvas[targetIdx];
                string leftBg = c > 0 ? DiffRenderer.PadVisible(existing, c, resetBeforeFill: true) : string.Empty;
                int rightStart = c + w;
                string rightBg = string.Empty;
                if (rightStart < canvasWidth)
                {
                    int rem = canvasWidth - rightStart;
                    rightBg = new string(' ', rem);
                }
                canvas[targetIdx] = DiffRenderer.ClampAndPad(leftBg + boxLines[i] + rightBg, canvasWidth);
            }
        }
    }
}
