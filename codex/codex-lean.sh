# Sourced by cx.sh, codex-run.sh and partner-wait.sh. Flags that keep a Claude-driven `codex exec`
# lean without touching the Desktop app's config (2026-10-05).
# Measured on a one-word gpt-6.1-sol probe: 13,062 tokens before the whole cleanup, 7,513 after
# (config trimmed + these flags). The flags drop the auto-loaded memory summary (about 3.6k tokens),
# the multi-agent and tool-suggestion prompt blocks, and stop background memory generation.
CODEX_LEAN=(--disable multi_agent --disable tool_suggest
  -c features.memories=false -c memories.use_memories=false -c memories.generate_memories=false)
