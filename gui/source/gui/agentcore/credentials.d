/**
 * Agent configuration for the embedded Big Pickle client.
 *
 * Config lives beside the project transcript in `<project>/.dcad/config.toml`.
 * The installed OpenCode CLI's auth store is deliberately not read. Free Big
 * Pickle requests use the same public API key OpenCode uses; a real key can be
 * saved with `/auth` or supplied through the environment overrides.
 */
module gui.agentcore.credentials;

import std.algorithm.searching : countUntil;
import std.file : exists, mkdirRecurse, readText, remove, rename, write;
import std.path : dirName;
import std.process : environment;
import std.array : join;
import std.string : strip, splitLines;
import gui.agentcore.paths : agentConfigPath;

enum defaultAgentBaseURL = "https://opencode.ai/inference/openai/v1";

/// OpenCode enables free `opencode/*` models with this literal key when no
/// account is connected. The inference service uses it as a public client
/// identifier; it is not a secret.
enum publicAgentAPIKey = "public";

struct AgentCredential
{
    string apiKey = publicAgentAPIKey;
    string baseURL = defaultAgentBaseURL;

    bool hasKey() const @property
    {
        return apiKey.length != 0;
    }
}

final class AgentCredentials
{
    AgentCredential load(string projectRoot = "")
    {
        AgentCredential result;
        auto path = agentConfigPath(projectRoot);
        if (exists(path))
        {
            try
            {
                foreach (raw; splitLines(readText(path)))
                {
                    auto line = strip(raw);
                    if (!line.length || line[0] == '#') continue;
                    auto equal = countUntil(line, '=');
                    if (equal < 0) continue;
                    auto key = strip(line[0 .. equal]);
                    auto value = unquoteToml(strip(line[equal + 1 .. $]));
                    switch (key)
                    {
                        case "api_key":
                            if (value.length) result.apiKey = value;
                            break;
                        case "base_url":
                            if (value.length) result.baseURL = value;
                            break;
                        default:
                            break;
                    }
                }
            }
            catch (Exception)
            {
                // A corrupt local config behaves like the free default.
            }
        }

        auto envKey = environment.get("DCAD_AGENT_API_KEY", "");
        if (envKey.length) result.apiKey = envKey;
        auto envURL = environment.get("DCAD_AGENT_BASE_URL", "");
        if (envURL.length) result.baseURL = envURL;
        if (!result.apiKey.length) result.apiKey = publicAgentAPIKey;
        if (!result.baseURL.length) result.baseURL = defaultAgentBaseURL;
        return result;
    }

    void save(AgentCredential credential, string projectRoot = "")
    {
        auto path = agentConfigPath(projectRoot);
        mkdirRecurse(dirName(path));

        // The same file also stores project metadata. Replace only the two
        // credential keys so `/auth` cannot erase `name`, `entry` or comments.
        string[] kept;
        if (exists(path))
        {
            try
            {
                foreach (raw; splitLines(readText(path)))
                {
                    auto line = strip(raw);
                    auto equal = countUntil(line, '=');
                    if (equal >= 0)
                    {
                        auto key = strip(line[0 .. equal]);
                        if (key == "api_key" || key == "base_url")
                            continue;
                    }
                    kept ~= raw;
                }
            }
            catch (Exception)
            {
                // A corrupt config is replaced with a fresh one.
                kept = null;
            }
        }
        string text = kept.length
            ? kept.join("\n") ~ "\n"
            : "# dcad project configuration\n";
        text ~= "api_key = " ~ quoteToml(credential.apiKey.length
                                         ? credential.apiKey
                                         : publicAgentAPIKey) ~ "\n"
             ~ "base_url = " ~ quoteToml(credential.baseURL.length
                                         ? credential.baseURL
                                         : defaultAgentBaseURL) ~ "\n";

        auto temporary = path ~ ".tmp";
        write(temporary, text);
        if (exists(path)) remove(path);
        rename(temporary, path);
    }

private:
    static string unquoteToml(string value)
    {
        if (value.length < 2 || value[0] != '"' || value[$-1] != '"')
            return value;
        auto inner = value[1 .. $-1];
        string result;
        for (size_t i = 0; i < inner.length; ++i)
        {
            if (inner[i] != '\\' || i + 1 == inner.length)
            {
                result ~= inner[i];
                continue;
            }
            ++i;
            switch (inner[i])
            {
                case 'n': result ~= '\n'; break;
                case 't': result ~= '\t'; break;
                case 'r': result ~= '\r'; break;
                case '"': result ~= '"'; break;
                case '\\': result ~= '\\'; break;
                default:  result ~= inner[i]; break;
            }
        }
        return result;
    }

    static string quoteToml(string value)
    {
        string result = "\"";
        foreach (char c; value)
        {
            switch (c)
            {
                case '\n': result ~= "\\n"; break;
                case '\t': result ~= "\\t"; break;
                case '\r': result ~= "\\r"; break;
                case '"':  result ~= "\\\""; break;
                case '\\': result ~= "\\\\"; break;
                default:   result ~= c; break;
            }
        }
        return result ~ "\"";
    }
}
