/**
 * Small UI-facing transcript types shared by the legacy CLI adapter and the
 * embedded agent core. The schema port lives in gui.agentcore.schema; these types
 * are the flattened projection consumed by the Agent tab.
 */
module gui.agentcore.messages;

enum AgentRole
{
    user,
    assistant,
    tool,
    error,
    status
}

struct AgentMessage
{
    AgentRole role;
    string text;
    /// Assistant part id used to coalesce streamed text deltas.
    string key;
}

/// Stable role name used in project history JSONL.
string agentRoleName(AgentRole role)
{
    final switch (role)
    {
        case AgentRole.user: return "user";
        case AgentRole.assistant: return "assistant";
        case AgentRole.tool: return "tool";
        case AgentRole.error: return "error";
        case AgentRole.status: return "status";
    }
}
