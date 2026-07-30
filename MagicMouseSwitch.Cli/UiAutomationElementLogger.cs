using System.Windows.Automation;

namespace MagicMouseSwitch.Cli;

internal sealed class UiAutomationElementLogger(OperationLogger logger)
{
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);

    internal void LogTree(string stage, AutomationElement root, bool writeConsole = false)
    {
        Log(stage, root, writeConsole);
        AutomationElementCollection elements;
        try
        {
            elements = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        }
        catch (ElementNotAvailableException)
        {
            return;
        }

        foreach (AutomationElement element in elements)
        {
            Log(stage, element, writeConsole);
        }
    }

    internal void LogAncestorChain(string stage, AutomationElement element, bool writeConsole)
    {
        AutomationElement? current = element;
        int level = 0;
        while (current is not null)
        {
            string prefix = $"ancestor[{level}]";
            if (writeConsole)
            {
                Console.WriteLine($"{prefix}: {Describe(current)}");
            }

            Log($"{stage}_{prefix}", current);
            if (Automation.Compare(current, AutomationElement.RootElement))
            {
                break;
            }

            try
            {
                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            catch (ElementNotAvailableException)
            {
                break;
            }

            level++;
        }
    }

    internal void Log(string stage, AutomationElement element, bool writeConsole = false)
    {
        string description;
        string runtimeId;
        try
        {
            description = Describe(element);
            runtimeId = string.Join(".", element.GetRuntimeId());
        }
        catch (ElementNotAvailableException)
        {
            logger.Info("ui_element", $"stage={Quote(stage)} unavailable=true");
            return;
        }

        if (writeConsole)
        {
            Console.WriteLine(description);
        }

        if (_seen.Add($"{stage}|{runtimeId}"))
        {
            logger.Info("ui_element", $"stage={Quote(stage)} {description}");
        }
    }

    internal static string Describe(AutomationElement element)
    {
        AutomationElement.AutomationElementInformation current = element.Current;
        AutomationElement? parent = null;
        try
        {
            parent = TreeWalker.RawViewWalker.GetParent(element);
        }
        catch (ElementNotAvailableException)
        {
            // The remaining element properties can still be logged.
        }

        string parentName = string.Empty;
        string parentType = string.Empty;
        if (parent is not null)
        {
            try
            {
                parentName = parent.Current.Name;
                parentType = parent.Current.ControlType.ProgrammaticName;
            }
            catch (ElementNotAvailableException)
            {
                parentName = "<unavailable>";
            }
        }

        string patterns = string.Join(",", element.GetSupportedPatterns().Select(pattern => pattern.ProgrammaticName));
        return
            $"name={Quote(current.Name)} control_type={Quote(current.ControlType.ProgrammaticName)} " +
            $"automation_id={Quote(current.AutomationId)} class={Quote(current.ClassName)} " +
            $"patterns={Quote(patterns)} parent_name={Quote(parentName)} parent_control_type={Quote(parentType)} " +
            $"process_id={current.ProcessId} enabled={current.IsEnabled}";
    }

    private static string Quote(string? value) => $"\"{(value ?? string.Empty).Replace("\"", "'")}\"";
}
