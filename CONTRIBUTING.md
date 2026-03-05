---
title: Contributing to serverpod-flutter-expert
---

# Contributing to serverpod-flutter-expert

Thank you for your interest in contributing! This skill grows through community knowledge. Every improvement makes AI agents better at helping Serverpod and Flutter developers.

---

## Table of Contents

- [How to Report Bugs](#how-to-report-bugs)
- [How to Suggest Enhancements](#how-to-suggest-enhancements)
- [How to Add Examples](#how-to-add-examples)
- [How to Improve Documentation](#how-to-improve-documentation)
- [How to Add References](#how-to-add-references)
- [Skill Structure](#skill-structure)
- [Pull Request Process](#pull-request-process)
- [Style Guidelines](#style-guidelines)
- [First-Time Contributors](#first-time-contributors)
- [Community](#community)

---

## How to Report Bugs

Found incorrect code, outdated API usage, or misleading instructions?

1. Open a [GitHub Issue](../../issues/new).
2. Use the title format: `[Bug] Short description`.
3. Include:
   - Which file and section is wrong.
   - What the current content says.
   - What it should say (with a code example if possible).
   - The Serverpod version you are using.

---

## How to Suggest Enhancements

Have an idea for a new pattern, missing use case, or better explanation?

1. Open a [GitHub Issue](../../issues/new).
2. Use the title format: `[Enhancement] Short description`.
3. Describe:
   - The gap or problem the enhancement addresses.
   - A concrete example of what the new content would look like.
   - Whether it belongs in `SKILL.md`, `references/`, or `examples/`.

---

## How to Add Examples

The `examples/` folder contains copy-paste-ready Dart files. Good examples:

- Are complete and self-contained (do not assume hidden context).
- Include comments explaining non-obvious lines.
- Cover both the server endpoint and the Flutter client.
- Include error handling.
- Follow Dart and Serverpod conventions.

To add an example:

1. Create a `.dart` file in `examples/` (e.g., `examples/push-notifications.dart`).
2. Add a YAML frontmatter comment block at the top:
   ```dart
   // ---
   // title: Push Notifications Example
   // description: Send push notifications from a Serverpod endpoint using FCM
   // serverpod_version: ">=3.4.0"
   // ---
   ```
3. Reference it in `SKILL.md` under the relevant section or in a new section.
4. Open a Pull Request with your changes.

---

## How to Improve Documentation

The main documentation lives in:

- `SKILL.md` — core skill loaded by AI agents on every interaction. Keep it dense but clear.
- `references/*.md` — deep-dive documentation loaded on demand.
- `README.md` — human-readable overview.

When editing documentation:

- Prefer concrete examples over abstract explanations.
- Keep code examples short enough to be scannable.
- If a section is getting too long, move detailed content to a `references/` file and link to it from `SKILL.md`.

---

## How to Add References

References live in `references/` and are loaded by the AI only when the relevant topic is needed. Each file should:

- Start with YAML frontmatter.
- Have a clear H1 heading.
- Be focused on a single topic.
- Include at least one production-ready code example.

To add a reference file:

1. Create `references/my-topic.md`.
2. Add frontmatter:
   ```yaml
   ---
   title: My Topic
   description: Description of what this reference covers
   tags: [serverpod, dart, my-topic]
   ---
   ```
3. Mention the new file in `SKILL.md`'s reference index (if one exists) or in the relevant section.

---

## Skill Structure

Understanding the structure helps you contribute to the right place:

```
serverpod-flutter-expert/
├── SKILL.md           # AI reads this on every interaction — keep concise & complete
├── references/        # Deep-dive docs — loaded on demand by the AI
├── examples/          # Copy-paste Dart code — server + Flutter client
├── templates/         # Starter project templates
├── README.md          # Human-readable overview for GitHub
├── CONTRIBUTING.md    # This file
└── CODE_OF_CONDUCT.md # Community standards
```

**Rule of thumb:** If content is needed for 80%+ of Serverpod tasks, it belongs in `SKILL.md`. If it's specialized (advanced auth, specific deployment target), put it in `references/`.

---

## Pull Request Process

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/my-improvement
   ```

2. **Make your changes**, following the [Style Guidelines](#style-guidelines).

3. **Test your code examples** — all Dart code should be runnable with a standard Serverpod project.

4. **Open a Pull Request**:
   - Write a clear title and description.
   - Reference any related issues (`Fixes #123`).
   - Describe what changed and why.

5. A maintainer will review your PR within a few days. Feedback may be requested.

6. Once approved, your PR will be merged into `main`.

---

## Style Guidelines

### Markdown

- Use ATX headings (`#`, `##`, `###`), not underline style.
- Use fenced code blocks with language identifiers (` ```dart `, ` ```yaml `, ` ```bash `).
- Wrap lines at 100 characters in prose; code blocks can be longer.
- Tables for comparisons; lists for enumerations.

### Dart

- Follow the [Dart style guide](https://dart.dev/guides/language/effective-dart/style).
- Use `final` and `const` where appropriate.
- Prefer named parameters for functions with 3+ arguments.
- Always include error handling in examples.
- Do not use deprecated Serverpod APIs.

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(examples): add push notifications example
fix(skill): correct ORM deleteWhere syntax
docs(references): expand deployment with nginx config
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

---

## First-Time Contributors

New to open source? Here are good starting points:

- Fix a typo or improve a code comment.
- Add an example for a use case you've built.
- Improve an existing reference file with more detail.
- Add a new entry to the "Common Errors & Solutions" table in `SKILL.md`.

Look for issues labeled `good first issue` in the issue tracker.

---

## Community

- Be respectful and constructive in all interactions.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Questions? Open a Discussion on GitHub.

Thank you for helping make this skill better for everyone!
