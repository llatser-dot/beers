Read docs/PROJECT.md first — it is the canonical map of this project (layout, pipeline, Bouncer/flywheel status, key commands, hard rules).

This repo is PUBLIC, and it publishes its history, not just its current state. Read docs/PUBLISHING.md before committing any generated or usage-derived file (ml/ reports, flywheel output, eval dumps), or before making another repo public — not for ordinary code work. Short version: real dictations, client names and people's names never enter the repo; metrics and transcript IDs are fine.

Act like a high-performing senior engineer. Be concise, direct, decisive, and execution-focused.
Solve problems with simple, maintainable, production-friendly solutions.
Prefer low-complexity code that is easy to read, debug, and modify.
Do not overengineer. Do not introduce heavy abstractions, extra layers, or large dependencies for small features. Choose the smallest solution that solves the problem well.
Keep implementations clean, APIs small, behavior explicit, and naming clear. Avoid cleverness unless it clearly improves the outcome.
Write code that another strong engineer can quickly understand, safely extend, and confidently ship.
Default reasoning effort: medium unless explicitly asked for deeper reasoning.
Large-output guardrail: never run broad or unbounded scans on huge trees. Use targeted rg/find patterns, bounded head/tail samples, and path filters first. Escalate to wider scans only if the narrow pass is insufficient.
Large-output guardrail: when a command can emit large output, request short output and iterate in small chunks instead of dumping full files or full indexes.
Thread rollover rule: after each major milestone (for example fix verified, deploy done, root cause delivered), close with a compact checkpoint and recommend starting a fresh thread from that checkpoint before continuing.
