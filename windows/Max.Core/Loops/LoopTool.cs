using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>Lets Max create, list, and delete its own scheduled loops.</summary>
public sealed class LoopTool : IMaxTool
{
    public ToolSpec Spec => new(
        "loop",
        "Manage scheduled autonomous runs ('loops'). action=create schedules a recurring task; " +
        "action=list shows existing loops; action=delete removes one by id. For create, give a clear " +
        "prompt describing the task. schedule is 'every' (with interval_minutes), 'daily' (with time HH:mm), " +
        "or 'once' (with at, an ISO-8601 UTC timestamp).",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["action"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("create", "list", "delete") },
                ["name"] = new JsonObject { ["type"] = "string" },
                ["prompt"] = new JsonObject { ["type"] = "string" },
                ["schedule"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("every", "daily", "once") },
                ["interval_minutes"] = new JsonObject { ["type"] = "integer" },
                ["time"] = new JsonObject { ["type"] = "string", ["description"] = "HH:mm local, for daily" },
                ["at"] = new JsonObject { ["type"] = "string", ["description"] = "ISO-8601 UTC, for once" },
                ["id"] = new JsonObject { ["type"] = "string", ["description"] = "loop id, for delete" },
            },
            ["required"] = new JsonArray("action"),
        });

    public string Summary(JsonObject input) => $"loop {(string?)input["action"] ?? "?"}";

    public Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct)
    {
        var action = (string?)input["action"] ?? "list";
        switch (action)
        {
            case "create":
            {
                var loop = new LoopDef
                {
                    Name = (string?)input["name"] ?? "Untitled loop",
                    Prompt = (string?)input["prompt"] ?? "",
                    Schedule = Enum.TryParse<LoopSchedule>((string?)input["schedule"], true, out var s) ? s : LoopSchedule.Every,
                    IntervalMinutes = (int?)input["interval_minutes"] ?? 60,
                    Time = (string?)input["time"] ?? "09:00",
                    AtUtc = DateTime.TryParse((string?)input["at"], null, System.Globalization.DateTimeStyles.AdjustToUniversal, out var at) ? at : null,
                };
                if (string.IsNullOrWhiteSpace(loop.Prompt))
                    return Task.FromResult(ToolOutcome.Fail("a loop needs a prompt describing the task"));
                LoopStore.Upsert(loop);
                return Task.FromResult(ToolOutcome.Ok($"Created loop '{loop.Name}' (id {loop.Id}), schedule={loop.Schedule}."));
            }
            case "delete":
            {
                var id = (string?)input["id"];
                if (string.IsNullOrWhiteSpace(id)) return Task.FromResult(ToolOutcome.Fail("delete needs an id"));
                LoopStore.Delete(id!);
                return Task.FromResult(ToolOutcome.Ok($"Deleted loop {id}."));
            }
            default:
            {
                var all = LoopStore.Load();
                if (all.Count == 0) return Task.FromResult(ToolOutcome.Ok("No loops scheduled."));
                var sb = new StringBuilder();
                foreach (var l in all)
                    sb.AppendLine($"- [{l.Id}] {l.Name} — {l.Schedule}" +
                        (l.Schedule == LoopSchedule.Every ? $" {l.IntervalMinutes}m" :
                         l.Schedule == LoopSchedule.Daily ? $" @ {l.Time}" : $" @ {l.AtUtc:u}") +
                        (l.Enabled ? "" : " (done)"));
                return Task.FromResult(ToolOutcome.Ok(sb.ToString().TrimEnd()));
            }
        }
    }
}
