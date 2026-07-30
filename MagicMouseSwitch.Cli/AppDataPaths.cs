using System.IO;

namespace MagicMouseSwitch.Cli;

internal static class AppDataPaths
{
    internal static string RootDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MagicMouseSwitch");

    internal static string ConfigPath => Path.Combine(RootDirectory, "config.json");

    internal static string LogsDirectory => Path.Combine(RootDirectory, "logs");
}
