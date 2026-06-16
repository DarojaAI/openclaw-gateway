---
name: model-management
description: Manage AI models for OpenClaw agents. Use when user sends /model, /models, /model-list, /model-search, /model-switch, /model-cost, /model-info, or asks about available models, switching models, model costs, or context usage.
trigger: "/model"
---

# Model Management

You help the user discover, switch between, and track costs for OpenRouter models available to OpenClaw agents.

## Command Patterns

### List All Models
- "/model" or "/models" or "/model-list"
- "show me all models"
- "what models are available"
- "list models"

**Action:** Execute the command: `openclaw-model-manager list`

NEVER use `openclaw models scan` — it only shows free models. ALWAYS use `openclaw-model-manager list` to show the full catalog.

This shows the full OpenRouter catalog (not just configured aliases) with:
- Model ID and any configured alias in [brackets]
- Context window size
- Pricing per 1M tokens (input/output)
- Badges: 🧠 reasoning, 🖼️ vision, 📄 file upload, 🆓 free

If the user wants free models only, run: `openclaw-model-manager list --free-only`
If they want to sort by cost: `openclaw-model-manager list --sort cost`
If they want to sort by context size: `openclaw-model-manager list --sort context`
If they want only a specific provider: `openclaw-model-manager list --provider anthropic`

### Search Models
- "/model-search <query>"
- "find models like <query>"
- "search for <provider> models"

**Action:** Run `openclaw-model-manager search <query>`

### Switch Model
- "/model <alias>" or "/model-switch <model>"
- "switch to <alias_or_model>"
- "use <model>"
- "change model to <model>"

**Action:** Run `openclaw-model-manager switch <target>`

This resolves aliases (like `burns`, `coder`, `ensign`) or accepts full model IDs. If the model is not in the local config, it auto-imports from OpenRouter. Then updates the default model and prompts for gateway restart.

After switching, inform the user:
1. What model they switched to
2. That a gateway restart is required
3. Provide the restart command: `systemctl --user restart openclaw-gateway.service`

### Show Model Info
- "/model-info <model>"
- "tell me about <model>"
- "what is <model>"

**Action:** Run `openclaw-model-manager info <model>`

Shows: name, ID, context, pricing, reasoning support, modalities, and recent usage/cost data.

### Show Current Model
- "/model status" or "/model current"
- "what model am I using"
- "current model"

**Action:** Run `openclaw-model-manager current`

### Show Costs
- "/model-cost" or "/cost"
- "how much did I spend"
- "model costs"
- "what did <model> cost"

**Action:** Run `openclaw-model-manager cost [--days N] [--model <model_id>]`

Shows per-model cost breakdown with ASCII bar charts. Default is 7 days. Use --days 1 for daily spend.

### Show Context Health
- "/model-context" or "/context-health"
- "context usage"
- "how is my context"

**Action:** Run `openclaw-model-manager context [--days N]`

Shows context compaction efficiency. Warns if >80% reserve usage detected in 3+ recent runs.

## Response Formatting

When presenting model lists to Discord:
- Use code blocks for structured output
- Keep responses concise but informative
- Highlight free models and reasoning models
- Mention aliases clearly
- For cost data, use the ASCII bar charts as provided by the script

## Examples

**User:** /model

**You:**
Here are all available OpenRouter models:

```
anthropic/claude-sonnet-4-5 [burns]
  Claude Sonnet 4.5 | Context: 200K | $3.00/$15.00 per 1M 🧠

minimax/MiniMax-M2.7 [coder]
  MiniMax-M2.7 | Context: 100K | free 🧠

tencent/hy3-preview:free [frida]
  Tencent: Hy3 preview (free) | Context: 262K | free
```

**User:** switch to claude-haiku-4-5

**You:**
Switching to anthropic/claude-haiku-4-5 (ensign)...

✅ Switched default model: openrouter/minimax/MiniMax-M2.7 → openrouter/anthropic/claude-haiku-4-5

⚠️ Restart required to apply:
`systemctl --user restart openclaw-gateway.service`

Or run: `openclaw gateway restart`

**User:** how much did burns cost today

**You:**
📊 Cost for anthropic/claude-sonnet-4-5 (last 1 days)

  Total Cost:   $0.42
  Calls:        3
  Prompt Tokens: 12,450
  Completion Tokens: 8,920
  Avg per Call: $0.14

---

**User:** search for free vision models

**You:**
Searching OpenRouter catalog...

```
meta-llama/llama-4-scout:free
  Llama 4 Scout (free) | Context: 256K | free 🖼️

google/gemini-2.5-pro-exp-03-25:free
  Gemini 2.5 Pro Experimental (free) | Context: 1M | free 🧠 🖼️ 📄
```

Use `openclaw-model-manager switch <id>` to enable any of these.
