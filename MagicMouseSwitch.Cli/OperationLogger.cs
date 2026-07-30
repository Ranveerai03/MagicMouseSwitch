using System.Diagnostics;
using System.IO;

namespace MagicMouseSwitch.Cli;

internal sealed class OperationLogger
{
    private readonly string _logPath;
    private readonly object _gate = new();

    internal OperationLogger()
    {
        string logDirectory = AppDataPaths.LogsDirectory;
        Directory.CreateDirectory(logDirectory);
        _logPath = Path.Combine(logDirectory, $"magic-mouse-switch-{DateTime.Now:yyyyMMdd}.log");
    }

    internal string LogPath => _logPath;

    internal void Info(string operation, string message, Stopwatch? elapsed = null) =>
        Write("INFO", operation, message, elapsed);

    internal void Error(string operation, Exception exception, Stopwatch? elapsed = null) =>
        Write("ERROR", operation, $"{exception.GetType().Name}: {exception.Message}", elapsed);

    private void Write(string level, string operation, string message, Stopwatch? elapsed)
    {
        string duration = elapsed is null ? string.Empty : $" elapsed_ms={elapsed.ElapsedMilliseconds}";
        string line = $"{DateTimeOffset.Now:O} [{level}] operation={operation}{duration} {message}";
        lock (_gate)
        {
            File.AppendAllText(_logPath, line + Environment.NewLine);
        }
    }
}
