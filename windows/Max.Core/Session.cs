namespace Max.Core;

/// <summary>One conversation, persisted as JSONL (one ChatTurn per line) under sessions/.</summary>
public sealed class ChatSession
{
    public string Id { get; }
    private readonly string _path;
    private readonly List<ChatTurn> _turns = new();
    private readonly object _gate = new();

    public ChatSession(string id)
    {
        Id = id;
        MaxPaths.Ensure();
        _path = Path.Combine(MaxPaths.Sessions, $"{id}.jsonl");
        if (File.Exists(_path))
        {
            foreach (var line in File.ReadAllLines(_path))
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try { _turns.Add(ChatTurn.FromJsonLine(line)); } catch { }
            }
        }
    }

    public IReadOnlyList<ChatTurn> Turns
    {
        get { lock (_gate) return _turns.ToList(); }
    }

    public void Append(ChatTurn turn)
    {
        lock (_gate)
        {
            _turns.Add(turn);
            File.AppendAllText(_path, turn.ToJsonLine() + Environment.NewLine);
        }
    }
}

/// <summary>Index over the saved conversations (newest first).</summary>
public static class Conversations
{
    public static string NewId() => $"conv-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid().ToString("N")[..6]}";

    public static IReadOnlyList<string> List()
    {
        MaxPaths.Ensure();
        return Directory.GetFiles(MaxPaths.Sessions, "*.jsonl")
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .Select(p => Path.GetFileNameWithoutExtension(p))
            .ToList();
    }

    public static string? MostRecentId() => List().FirstOrDefault();

    public static void Delete(string id)
    {
        var p = Path.Combine(MaxPaths.Sessions, $"{id}.jsonl");
        try { if (File.Exists(p)) File.Delete(p); } catch { }
    }
}
