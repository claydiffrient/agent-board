# Agent Board — Specification

A native macOS app that manages work for Claude Code agents: an orchestrator you
talk to, a board of tasks it decomposes work into, a roster of running agents,
and a shared notes surface those agents read and write.

Status: pre-implementation. Derived from `IDEA.md` by decision interview.

---

Each numbered section lives in its own file under `docs/spec/`, named for its
number. A citation's number is its address: `SPEC §9.1` is the `### 9.1` heading
in `docs/spec/09-*.md`, and a decision id such as `D8` is a row in §1.
Subsections stay in their parent's file. Numbers do not change when a title does.

- **§1 [Decisions](docs/spec/01-decisions.md)** — the D1–D20 table: each
  design decision, its one-line rationale, and the alternative it rejected.

- **§2 [Platform facts this spec depends on](docs/spec/02-platform-facts.md)** —
  Claude Code behavior the design rests on (`--bg`, `claude agents`, hooks,
  MCP config, resume), and which of it was proven by experiment.

- **§3 [Architecture](docs/spec/03-architecture.md)** — the app's components and
  processes. §3.1 Spawn procedure · §3.2 Listening ports

- **§4 [Data model](docs/spec/04-data-model.md)** — the SQLite schema, every
  table and column, and the rules behind them. §4.1 Opening the database:
  newer-build refusal and launch backups

- **§5 [Task lifecycle](docs/spec/05-task-lifecycle.md)** — the columns, and
  what moves a task between them. §5.1 Completion protocol · §5.2 Epic
  integration

- **§6 [MCP surface](docs/spec/06-mcp-surface.md)** — resources, prompts, and
  the tools each token scope sees: worker, reviewer, orchestrator, Coordinator.
  §6.1 Remote branch naming

- **§7 [Hook contract](docs/spec/07-hook-contract.md)** — each hook event a
  managed session posts, and how the board reacts to it.

- **§8 [Safety and limits](docs/spec/08-safety-and-limits.md)** — per-project
  caps and what a breach does, and the guards no prompt can talk past.
  §8.1 Shutdown order · §8.2 Cross-project authority boundary · §8.3 Sleep
  prevention · §8.4 Shared-checkout file locks · §8.5 Session end reaps the
  process tree

- **§9 [Orchestrator](docs/spec/09-orchestrator.md)** — the per-project
  orchestrator session: how it starts, what it is told, how it hears back.
  §9.1 Report channel · §9.2 Compaction · §9.3 Cross-project messages ·
  §9.4 Coordinator requests

- **§10 [Screens](docs/spec/10-screens.md)** — every screen, one bold-titled
  entry each: At a Glance, Shut Down, Orchestrator Command, Stop All, Terminal,
  Task Board, Status, Roster, Coordinator, Notes, Project sidebar, Ports,
  Project settings, What's New in Agent Board. §10.1 Main window size

- **§11 [Milestones](docs/spec/11-milestones.md)** — M0–M4, what each proved,
  and the gate it set for what came next.

- **§12 [Open items](docs/spec/12-open-items.md)** — what was verified live,
  what was not, accepted limitations, and what is unresolved.
