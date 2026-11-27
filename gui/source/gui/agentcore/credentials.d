/**
 * dcad-owned credentials for the embedded Big Pickle client.
 *
 * The installed OpenCode CLI's auth store is deliberately not read. The API
 * key lives in dcad's app cache; environment overrides make CI tests possible
 * without touching a developer's account.
 */
module gui.agentcore.credentials;

import std.file : exists, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.process : environment;
import gui.agentcore.paths : agentCredentialsPath;

enum defaultAgentBaseURL = "https://opencode.ai/inference/openai/v1";

struct AgentCredential
{
    string apiKey;
    string baseURL = defaultAgentBaseURL;

    bool hasKey() const @property
    {
        return apiKey.length != 0;
    }
}

final class AgentCredentials
{
    AgentCredential load()
    {
        AgentCredential result;
        auto path = agentCredentialsPath();
        if (exists(path))
        {
            try
            {
                auto root = parseJSON(readText(path));
                result.apiKey = stringField(root, "api_key", "apiKey");
                result.baseURL = stringField(root, "base_url", "baseURL",
                                             defaultAgentBaseURL);
            }
            catch (Exception)
            {
                // A corrupt local config behaves like a missing key; the user
                // can re-enter it in the Agent tab.
            }
        }

        auto envKey = environment.get("DCAD_AGENT_API_KEY", "");
        if (envKey.length) result.apiKey = envKey;
        auto envURL = environment.get("DCAD_AGENT_BASE_URL", "");
        if (envURL.length) result.baseURL = envURL;
        return result;
    }

    void save(AgentCredential credential)
    {
        auto path = agentCredentialsPath();
        mkdirRecurse(dirName(path));

        JSONValue[string] object;
        object["api_key"] = JSONValue(credential.apiKey);
        object["base_url"] = JSONValue(credential.baseURL.length
                                       ? credential.baseURL : defaultAgentBaseURL);

        auto temporary = path ~ ".tmp";
        write(temporary, JSONValue(object).toString());
        if (exists(path)) remove(path);
        rename(temporary, path);
    }

    private string stringField(JSONValue root, string first, string second,
                               string fallback = "")
    {
        if (root.type != JSONType.object) return fallback;
        if (auto value = first in root.object)
            if (value.type == JSONType.string) return value.str;
        if (auto value = second in root.object)
            if (value.type == JSONType.string) return value.str;
        return fallback;
    }
}
