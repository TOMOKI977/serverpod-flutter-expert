---
title: serverpod-flutter-expert
description: A skills.sh skill for Serverpod 3.4.x + Flutter full-stack development
---

# serverpod-flutter-expert

[![skills.sh](https://img.shields.io/badge/skills.sh-compatible-blue)](https://skills.sh)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Serverpod 3.4.x](https://img.shields.io/badge/Serverpod-3.4.x-orange)](https://serverpod.dev)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-green)](https://claude.ai/code)
[![Cursor](https://img.shields.io/badge/Cursor-compatible-green)](https://cursor.sh)
[![Gemini CLI](https://img.shields.io/badge/Gemini%20CLI-compatible-green)](https://gemini.google.com)

> A comprehensive expert skill that teaches AI coding agents **Serverpod 3.4.x** and Flutter best practices — models, ORM, endpoints, authentication, WebSockets, migrations, and production deployment — using the latest stable APIs and modern Dart null-safety syntax.

---

## Installation

### Via npx (recommended)

```bash
npx skills add serverpod-flutter-expert
```

### Manual

Copy `SKILL.md` into your project root or your AI agent's context directory, then reference it in your agent configuration.

For Claude Code, add to `.claude/SKILL.md` or reference it in your `CLAUDE.md`:

```markdown
# Skills
@.claude/skills/serverpod-flutter-expert/SKILL.md
```

---

## What This Skill Does

| Capability | Coverage |
|-----------|---------|
| **Project structure** | Server, client, Flutter app layout |
| **Models** | `.spy.yaml` definitions, relationships, enums, indexes |
| **Endpoints** | Auth-aware RPC, per-method auth, error handling |
| **ORM queries** | find, insert, update, delete, transactions, count |
| **Authentication** | Email, Google, Apple, session management |
| **WebSockets** | Streaming endpoints, pub/sub channels, Flutter client |
| **File uploads** | Multipart, validation, storage paths |
| **Migrations** | Create, apply, rollback, production checklist |
| **Configuration** | Development / production YAML, secrets handling |
| **Deployment** | Docker, PostgreSQL, Redis, Nginx, TLS |
| **Testing** | `withServerpod` test harness, unit + integration |
| **Error reference** | Common errors, causes, and fixes |

---

## Usage Examples

### Before — outdated v2.x pattern (without this skill)

> **User:** "How do I add an authenticated endpoint?"
>
> **AI:** *(using old Serverpod 2.x API)*
>
> ```dart
> // ❌ Old v2.x pattern — do NOT use in 3.4.x
> class ProfileEndpoint extends Endpoint {
>   Future<UserProfile?> getMyProfile(Session session) async {
>     // Wrong: casting session is the v2 pattern
>     final userId = (session as AuthenticatedSession).userId;
>     return await UserProfile.db.findFirstRow(
>       session,
>       where: (t) => t.userId.equals(userId),
>     );
>   }
> }
> ```
>
> The AI uses deprecated v2.x session casting and missing exception types.

---

### After — correct v3.4.x pattern (with this skill)

> **User:** "How do I add an authenticated endpoint?"
>
> **AI:** *(using Serverpod 3.4.x API)*
>
> ```dart
> // ✅ Correct 3.4.x pattern
> // lib/src/endpoints/profile_endpoint.dart
> import 'package:serverpod/serverpod.dart';
> import '../generated/protocol.dart';
>
> class ProfileEndpoint extends Endpoint {
>   @override
>   bool get requireLogin => true;
>
>   Future<UserProfile?> getMyProfile(Session session) async {
>     // 3.4.x: use session.auth.authenticatedUserId (async, never cast session)
>     final userId = await session.auth.authenticatedUserId;
>     if (userId == null) throw ServerpodUnauthenticatedException();
>
>     return await UserProfile.db.findFirstRow(
>       session,
>       where: (t) => t.userId.equals(userId),
>     );
>   }
>
>   Future<UserProfile> updateProfile(
>     Session session,
>     String displayName,
>     String? bio,
>   ) async {
>     final userId = await session.auth.authenticatedUserId;
>     if (userId == null) throw ServerpodUnauthenticatedException();
>
>     final profile = await UserProfile.db.findFirstRow(
>       session,
>       where: (t) => t.userId.equals(userId),
>     );
>     // 3.4.x: use typed exceptions (NotFoundException, ForbiddenException)
>     if (profile == null) throw NotFoundException('Profile not found');
>
>     return await UserProfile.db.updateRow(
>       session,
>       profile.copyWith(
>         displayName: displayName.trim(),
>         bio: bio?.trim(),
>         updatedAt: DateTime.now().toUtc(),
>       ),
>     );
>   }
> }
> ```
>
> Then run:
> ```bash
> dart run serverpod_cli generate
> ```
>
> Flutter client (unchanged pattern, generated client handles auth automatically):
> ```dart
> final profile = await client.profile.getMyProfile();
> ```

The AI gives correct, idiomatic **Serverpod 3.4.x** code with proper async auth checks, typed exceptions, and UTC timestamps.

---

## Skill Structure

```
serverpod-flutter-expert/
├── SKILL.md                  # Core skill (loaded on every interaction)
├── references/
│   ├── authentication.md     # Auth deep-dive (loaded on demand)
│   ├── database-design.md    # Relationships, indexes, migrations
│   ├── websockets.md         # Real-time streaming patterns
│   ├── file-uploads.md       # File handling
│   └── deployment.md         # Production setup
├── examples/
│   ├── crud-example.dart     # Full CRUD server + Flutter client
│   ├── chat-example.dart     # WebSocket chat with rooms
│   └── auth-flow.dart        # Complete auth flow
├── templates/
│   └── minimal-server/       # Starter Serverpod server template
├── README.md
├── CONTRIBUTING.md
└── CODE_OF_CONDUCT.md
```

---

## Compatibility

| Tool | Status |
|------|--------|
| Claude Code | Fully compatible |
| Cursor | Fully compatible |
| Gemini CLI | Fully compatible |
| GitHub Copilot | Compatible (manual reference) |
| Continue.dev | Compatible (manual reference) |

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## License

MIT © Community — see [LICENSE](LICENSE).
