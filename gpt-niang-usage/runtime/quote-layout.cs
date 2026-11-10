using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// Rank candidates before building expensive glyph outlines. Validate the best
// candidates with the same WPF containment rules used by reviewed profiles.
public sealed class GptWidgetQuoteLayout {
  public double fontSize, width, lineHeight, offsetX, offsetY, score;
  public int lines;

  public static GptWidgetQuoteLayout Measure(string value, TextBlock text,
      Typeface typeface, double size, double width, int expectedLines) {
    var candidate = Score(value, text, typeface, size, width, expectedLines,
      StringInfo.ParseCombiningCharacters(value), false);
    return candidate == null ? null : Validate(candidate);
  }

  sealed class Candidate {
    public FormattedText text;
    public GptWidgetQuoteLayout layout;
    public int order;
  }

  static Candidate Score(string value, TextBlock text,
      Typeface typeface, double size, double width, int expectedLines, int[] indices, bool quickFit) {
    var formatted = new FormattedText(value, CultureInfo.CurrentCulture,
      FlowDirection.LeftToRight, typeface, size, text.Foreground, 1.0);
    formatted.MaxTextWidth = width;
    formatted.TextAlignment = TextAlignment.Center;
    formatted.LineHeight = size * 1.15;
    if (formatted.Height > 134) return null;
    if (quickFit) {
      // Line boxes are cheap to intersect and conservatively contain the ink.
      // Reviewed hints still use exact glyph fitting, retaining their typography.
      var box = formatted.BuildHighlightGeometry(new Point(0, 0));
      if (box == null || box.Bounds.IsEmpty) return null;
      box.Transform = new TranslateTransform(155 - box.Bounds.Left - box.Bounds.Width / 2,
        85 - box.Bounds.Top - box.Bounds.Height / 2);
      if (new EllipseGeometry(new Point(155, 85), 116, 67).FillContainsWithDetail(box)
          != IntersectionDetail.FullyContains) return null;
      int count = (int)Math.Ceiling(Math.Round(formatted.Height / formatted.LineHeight, 6));
      if (expectedLines > 0 && count != expectedLines) return null;
      return new Candidate { text = formatted, layout = new GptWidgetQuoteLayout {
        fontSize = size, width = width, lineHeight = size * 1.15, lines = count,
        score = size * 10 - Math.Max(0, count - 2) * 26 - (count - 1) * 8
      }};
    }
    var rows = new Dictionary<double, Rect>();
    for (int i = 0; i < indices.Length; i++) {
      int end = i + 1 < indices.Length ? indices[i + 1] : value.Length;
      var highlight = formatted.BuildHighlightGeometry(new Point(0, 0), indices[i], end - indices[i]);
      if (highlight == null || highlight.Bounds.IsEmpty) continue;
      var rect = highlight.Bounds;
      double key = Math.Round(rect.Top, 2);
      Rect row;
      if (rows.TryGetValue(key, out row)) { row.Union(rect); rows[key] = row; }
      else rows[key] = rect;
    }
    if (expectedLines > 0 && rows.Count != expectedLines) return null;
    double maximum = 0, minimum = double.MaxValue;
    foreach (var row in rows.Values) {
      maximum = Math.Max(maximum, row.Width);
      minimum = Math.Min(minimum, row.Width);
    }
    double imbalance = maximum > 0 ? 1 - minimum / maximum : 0;
    return new Candidate { text = formatted, layout = new GptWidgetQuoteLayout {
      fontSize = size, width = width, lineHeight = size * 1.15,
      lines = rows.Count,
      score = size * 10 - Math.Max(0, rows.Count - 2) * 26 - (rows.Count - 1) * 8 - imbalance * 55
    }};
  }

  static GptWidgetQuoteLayout Validate(Candidate candidate) {
    var formatted = candidate.text;
    var result = candidate.layout;
    var geometry = formatted.BuildGeometry(new Point(155 - result.width / 2, 85 - formatted.Height / 2));
    if (geometry.Bounds.IsEmpty) return null;
    result.offsetX = 155 - (geometry.Bounds.Left + geometry.Bounds.Width / 2);
    result.offsetY = 85 - (geometry.Bounds.Top + geometry.Bounds.Height / 2);
    geometry.Transform = new TranslateTransform(result.offsetX, result.offsetY);
    var interior = new EllipseGeometry(new Point(155, 85), 116, 67);
    return interior.FillContainsWithDetail(geometry) == IntersectionDetail.FullyContains ? result : null;
  }

  public static GptWidgetQuoteLayout Find(string value, TextBlock text,
      int expectedLines, double hintSize, double hintWidth, bool reviewed) {
    var typeface = new Typeface(text.FontFamily, text.FontStyle, text.FontWeight, text.FontStretch);
    var indices = StringInfo.ParseCombiningCharacters(value);
    GptWidgetQuoteLayout best = null;
    if (hintSize >= 10 && hintSize <= 32 && hintWidth >= 140 && hintWidth <= 236)
      best = Measure(value, text, typeface, hintSize, hintWidth, expectedLines);
    if (best != null) return best;
    var candidates = new List<Candidate>();
    for (int size = 32; size >= 6; size--) {
      for (int width = 236; width >= 140; width -= 8) {
        var candidate = Score(value, text, typeface, size, width, expectedLines, indices, !reviewed);
        if (candidate != null) { candidate.order = candidates.Count; candidates.Add(candidate); }
      }
      // Preserve the original preference for sizes >= 18 before considering
      // smaller text. There is no reason to outline every losing candidate.
      if (size == 18) {
        best = Best(candidates);
        if (best != null) return best;
        candidates.Clear();
      }
    }
    return Best(candidates);
  }

  static GptWidgetQuoteLayout Best(List<Candidate> candidates) {
    candidates.Sort((a, b) => {
      int score = b.layout.score.CompareTo(a.layout.score);
      return score == 0 ? a.order.CompareTo(b.order) : score;
    });
    foreach (var candidate in candidates) {
      var result = Validate(candidate);
      if (result != null) return result;
    }
    return null;
  }
}
