/**
 * Permission ruleset ported from OpenCode V2 semantics.
 *
 * Rules are evaluated in order and the last matching rule wins. For a request
 * with multiple resources, any deny denies; otherwise any ask asks; otherwise
 * allow. No match asks.
 */
module gui.agentcore.permissions;

import std.algorithm : canFind;
import std.json : JSONType, JSONValue;
import gui.agentcore.schema : agentField, agentStringField;

enum AgentPermissionEffect
{
    allow,
    deny,
    ask
}

enum AgentPermissionReply
{
    once,
    always,
    reject
}

struct AgentPermissionRule
{
    string action;
    string resource;
    AgentPermissionEffect effect;

    this(string action, string resource, AgentPermissionEffect effect)
    {
        this.action = action;
        this.resource = resource;
        this.effect = effect;
    }
}

struct AgentPermissionRequest
{
    string id;
    string sessionID;
    string action;
    string[] resources;
    bool save;
    string message;
}

struct AgentPermissionDecision
{
    enum Outcome { allow, ask, deny }

    Outcome outcome;
    string matchedRule;

    bool allowed() const @property { return outcome == Outcome.allow; }
    bool denied() const @property { return outcome == Outcome.deny; }
    bool needsAsk() const @property { return outcome == Outcome.ask; }
}

bool agentWildcardMatch(string pattern, string value)
{
    // Whole-string '*' and '?' matching, as used by upstream permission rules.
    size_t p, v, star, mark;
    while (v < value.length)
    {
        if (p < pattern.length && (pattern[p] == '?' || pattern[p] == value[v]))
        {
            ++p;
            ++v;
        }
        else if (p < pattern.length && pattern[p] == '*')
        {
            star = ++p;
            mark = v;
        }
        else if (star != 0)
        {
            p = star;
            v = ++mark;
        }
        else
            return false;
    }
    while (p < pattern.length && pattern[p] == '*') ++p;
    return p == pattern.length;
}

final class AgentPermissions
{
    private AgentPermissionRule[] rules;

    this(JSONValue ruleset = JSONValue.init)
    {
        addBaseRules();
        if (ruleset.type == JSONType.array)
            foreach (value; ruleset.array)
                addRule(parseRule(value));
    }

    void addRule(AgentPermissionRule rule)
    {
        rules ~= rule;
    }

    /// Saved "always" approvals cannot override a configured deny.
    void addSavedAllow(AgentPermissionRule rule)
    {
        foreach (existing; rules)
            if (existing.effect == AgentPermissionEffect.deny &&
                existing.action == rule.action &&
                agentWildcardMatch(existing.resource, rule.resource))
                return;
        addRule(rule);
    }

    AgentPermissionDecision decide(string action, string[] resources)
    {
        if (!resources.length) resources = ["*"];

        auto outcome = AgentPermissionDecision.Outcome.allow;
        string matched;

        foreach (resource; resources)
        {
            auto resourceOutcome = AgentPermissionDecision.Outcome.ask;
            string resourceMatch;

            foreach (rule; rules)
            {
                if (!agentWildcardMatch(rule.action, action)) continue;
                if (!agentWildcardMatch(rule.resource, resource)) continue;
                final switch (rule.effect)
                {
                    case AgentPermissionEffect.allow:
                        resourceOutcome = AgentPermissionDecision.Outcome.allow;
                        break;
                    case AgentPermissionEffect.ask:
                        resourceOutcome = AgentPermissionDecision.Outcome.ask;
                        break;
                    case AgentPermissionEffect.deny:
                        resourceOutcome = AgentPermissionDecision.Outcome.deny;
                        break;
                }
                resourceMatch = rule.resource;
            }

            if (resourceOutcome == AgentPermissionDecision.Outcome.deny)
                return AgentPermissionDecision(
                    AgentPermissionDecision.Outcome.deny, resourceMatch);
            if (resourceOutcome == AgentPermissionDecision.Outcome.ask)
            {
                outcome = AgentPermissionDecision.Outcome.ask;
                matched = resourceMatch;
            }
        }

        return AgentPermissionDecision(outcome, matched);
    }

    static AgentPermissionRule parseRule(JSONValue value)
    {
        AgentPermissionRule rule;
        rule.action = agentStringField(value, "action");
        rule.resource = agentStringField(value, "resource", "*");
        switch (agentStringField(value, "effect"))
        {
            case "allow": rule.effect = AgentPermissionEffect.allow; break;
            case "deny": rule.effect = AgentPermissionEffect.deny; break;
            default: rule.effect = AgentPermissionEffect.ask; break;
        }
        return rule;
    }

    private void addBaseRules()
    {
        addRule(AgentPermissionRule("*", "*", AgentPermissionEffect.allow));
        addRule(AgentPermissionRule("read", "*.env", AgentPermissionEffect.ask));
        addRule(AgentPermissionRule("read", "*.env.*", AgentPermissionEffect.ask));
        addRule(AgentPermissionRule("read", "*.env.example", AgentPermissionEffect.allow));
    }
}
