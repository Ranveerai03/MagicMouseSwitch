using System.Text;
using System.Text.RegularExpressions;

namespace MagicMouseSwitch.Cli;

internal static partial class UiTextNormalizer
{
    private const string MagicMouse = "Magic Mouse";

    internal static string Normalize(string? value)
    {
        string normalized = (value ?? string.Empty)
            .Normalize(NormalizationForm.FormKC)
            .Replace('\u2018', '\'')
            .Replace('\u2019', '\'')
            .Trim();
        return RepeatedWhitespace().Replace(normalized, " ");
    }

    internal static bool ContainsMagicMouse(string? value) =>
        Normalize(value).Contains(MagicMouse, StringComparison.OrdinalIgnoreCase);

    internal static bool EqualsNormalized(string? left, string? right) =>
        string.Equals(Normalize(left), Normalize(right), StringComparison.OrdinalIgnoreCase);

    [GeneratedRegex(@"\s+")]
    private static partial Regex RepeatedWhitespace();
}
