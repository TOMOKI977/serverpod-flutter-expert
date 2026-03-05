---
title: Minimal Serverpod 3.4.x Server Template
description: A minimal but complete Serverpod 3.4.x starter template with one model, one endpoint, and working configuration.
---

# Minimal Serverpod 3.4.x Server Template

A ready-to-run Serverpod backend with the smallest possible footprint — one model, one endpoint, and all the config wired up correctly.

---

## What's Included

```
minimal-server/
├── bin/
│   └── main.dart                        # Server entry point
├── lib/
│   └── src/
│       ├── endpoints/
│       │   └── greeting_endpoint.dart   # Example endpoint
│       └── models/
│           └── greeting.spy.yaml        # Example model
├── config/
│   ├── development.yaml                 # Local dev config
│   └── passwords.yaml.template          # Secrets template (copy → passwords.yaml)
├── pubspec.yaml
└── .gitignore
```

---

## Quick Start

### 1. Copy the template

```bash
cp -r templates/minimal-server my_new_server
cd my_new_server
```

### 2. Rename the package

Edit `pubspec.yaml` and replace `minimal_server` with your project name throughout.

### 3. Set up secrets

```bash
cp config/passwords.yaml.template config/passwords.yaml
# Edit config/passwords.yaml and fill in your database password
```

### 4. Start PostgreSQL (Docker)

```bash
docker run -d \
  --name serverpod-db \
  -e POSTGRES_DB=minimal_server_development \
  -e POSTGRES_USER=minimal_server \
  -e POSTGRES_PASSWORD=mysecretpassword \
  -p 5432:5432 \
  postgres:16-alpine
```

### 5. Install dependencies and generate code

```bash
dart pub get
dart run serverpod_cli generate
```

### 6. Apply migrations and start the server

```bash
dart run bin/main.dart --apply-migrations
```

The server will be available at `http://localhost:8080`.

---

## Adding a New Model

1. Create `lib/src/models/my_model.spy.yaml`
2. Run `dart run serverpod_cli generate`
3. The ORM class and migration are generated automatically.
4. Restart with `--apply-migrations`.

## Adding a New Endpoint

1. Create `lib/src/endpoints/my_endpoint.dart` extending `Endpoint`
2. Run `dart run serverpod_cli generate`
3. The client stub is generated in the client package automatically.

---

## Next Steps

- Add authentication: include `serverpod_auth_server` in `pubspec.yaml`
- Add the Flutter client: reference the generated `*_client` package from your Flutter app
- See the full skill documentation in `SKILL.md` for patterns and best practices
