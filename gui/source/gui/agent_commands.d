/**
 * Slash commands for dcad's keyboard-first Agent pane.
 *
 * The pane deliberately has no buttons: this parser lets every UI action be
 * typed into the prompt, including credentials and staged-change review.
 */
module gui.agent_commands;

import std.string : strip, toLower;

struct AgentCommand
{
    /// True when the input starts with '/'.
    bool valid;

    /// Command name without the leading '/' and lower-cased.
    string name;

    /// Remaining arguments, trimmed.
    string args;
}

/// Parse a prompt line. Plain text is left for the model and is not a command.
AgentCommand parseAgentCommand(string input)
{
    immutable text = strip(input);
    if (!text.length || text[0] != '/') return AgentCommand.init;

    size_t end = 1;
    while (end < text.length && text[end] != ' ' && text[end] != '\t')
        ++end;
    return AgentCommand(true, toLower(text[1 .. end]), strip(text[end .. $]));
}

/// Split whitespace-separated command arguments.
string[] agentCommandArgs(string args)
{
    string[] result;
    size_t index = 0;
    while (index < args.length)
    {
        while (index < args.length && (args[index] == ' ' || args[index] == '\t'))
            ++index;
        immutable start = index;
        while (index < args.length && args[index] != ' ' && args[index] != '\t')
            ++index;
        if (index > start) result ~= args[start .. index];
    }
    return result;
}

/// Text shown by `/commands` and `/help`.
string agentCommandHelp()
{
    return "Agent commands\n"
         ~ "/commands, /help     show this list\n"
         ~ "/stop                interrupt the running turn (Esc)\n"
         ~ "/diff                show or hide the staged diff\n"
         ~ "/keep                keep staged edits\n"
         ~ "/undo                revert staged edits\n"
         ~ "/model               show the active model and endpoint\n"
         ~ "/auth <key|public>   save key/URL in .dcad/config.toml\n"
         ~ "/status              show session and agent state\n";
}
