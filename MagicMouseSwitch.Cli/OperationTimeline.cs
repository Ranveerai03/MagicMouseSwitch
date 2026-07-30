using System.Collections.Concurrent;
using System.Diagnostics;

namespace MagicMouseSwitch.Cli;

internal sealed class OperationTimeline(OperationLogger logger)
{
    private static readonly string[] DisplayOrder =
    [
        "confirmation_accepted",
        "paired_endpoint_lookup_started",
        "saved_device_id_loaded",
        "direct_create_from_id_started",
        "direct_create_from_id_completed",
        "direct_endpoint_validation_completed",
        "fallback_enumeration_started",
        "fallback_endpoint_found",
        "paired_endpoint_resolved",
        "unpair_started",
        "unpair_completed",
        "unpaired_state_confirmed",
        "settings_opened",
        "add_device_button_invoked",
        "add_device_dialog_found",
        "magic_mouse_ui_row_found",
        "visible_exact_name_row_found",
        "pinned_bluetooth_endpoint_found",
        "row_selected",
        "row_selected_before_endpoint_discovery",
        "paired_endpoint_address_verified",
        "paired_state_confirmed",
        "connected_state_confirmed",
        "cursor_movement_confirmed",
        "pairing_dialog_closed",
        "settings_window_closed",
        "reused_existing_settings_window_left_open"
    ];

    private readonly Stopwatch _elapsed = Stopwatch.StartNew();
    private readonly ConcurrentDictionary<string, TimeSpan> _marks = new(StringComparer.Ordinal);

    internal TimeSpan Elapsed => _elapsed.Elapsed;

    internal void Mark(string name, string? detail = null)
    {
        TimeSpan value = _elapsed.Elapsed;
        if (_marks.TryAdd(name, value))
        {
            logger.Info("timing", $"event={name} elapsed_ms={value.TotalMilliseconds:0} {detail}".TrimEnd());
        }
    }

    internal void Progress(string name, string message, string? detail = null)
    {
        Mark(name, detail);
        Console.WriteLine($"[{_elapsed.Elapsed.TotalSeconds:0.000}s] {message}");
        Console.Out.Flush();
    }

    internal void PrintSummary()
    {
        Console.WriteLine();
        Console.WriteLine("Timing summary:");
        foreach (string name in DisplayOrder)
        {
            string value = _marks.TryGetValue(name, out TimeSpan elapsed)
                ? $"{elapsed.TotalSeconds,6:0.000}s"
                : "   n/a ";
            Console.WriteLine($"  {value}  {name.Replace('_', ' ')}");
        }

        Console.WriteLine($"  {_elapsed.Elapsed.TotalSeconds,6:0.000}s  total");
    }
}
