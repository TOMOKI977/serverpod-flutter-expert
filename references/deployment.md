---
title: Deployment Reference
description: Complete production deployment guide for Serverpod 3.4.x — Docker, PostgreSQL, Redis, Nginx, environment management, monitoring, and scaling.
tags: [serverpod, deployment, docker, postgresql, redis, nginx, production]
---

# Production Deployment — Serverpod 3.4.x

---

## 1. Prerequisites

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| PostgreSQL | 14 | 16 recommended |
| Redis | 6.2 | Required for multi-instance deployments |
| Dart SDK | 3.3+ | Use Docker `dart:stable` image |
| Docker | 24+ | |
| Docker Compose | 2.20+ | |

---

## 2. Dockerfile

```dockerfile
# my_project_server/Dockerfile
# ── Build stage ────────────────────────────────────────────────────────────────
FROM dart:stable AS build
WORKDIR /app

# Cache pub dependencies
COPY pubspec.* ./
RUN dart pub get --no-precompile

# Copy source and generate
COPY . .
RUN dart run serverpod_cli generate
RUN dart compile exe bin/main.dart -o bin/server

# ── Runtime stage ──────────────────────────────────────────────────────────────
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/server ./server
COPY --from=build /app/config ./config
COPY --from=build /app/migrations ./migrations

# Runtime user (never run as root)
RUN useradd --no-create-home --shell /bin/false appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080 8081
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8081/health || exit 1

CMD ["./server", "--mode", "production", "--apply-migrations"]
```

---

## 3. docker-compose.yml (Production)

```yaml
# docker-compose.yml
version: '3.9'

services:
  # ── PostgreSQL ───────────────────────────────────────────────────────────────
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_NAME:-myproject}
      POSTGRES_USER: ${DB_USER:-myproject}
      POSTGRES_PASSWORD: ${DB_PASSWORD:?DB_PASSWORD is required}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./scripts/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-myproject}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend

  # ── Redis ────────────────────────────────────────────────────────────────────
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD:?REDIS_PASSWORD is required}
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend

  # ── Serverpod Server ─────────────────────────────────────────────────────────
  server:
    build:
      context: ./my_project_server
      dockerfile: Dockerfile
    restart: unless-stopped
    environment:
      SERVERPOD_DATABASE_HOST: postgres
      SERVERPOD_DATABASE_PORT: "5432"
      SERVERPOD_DATABASE_NAME: ${DB_NAME:-myproject}
      SERVERPOD_DATABASE_USER: ${DB_USER:-myproject}
      SERVERPOD_DATABASE_PASSWORD: ${DB_PASSWORD}
      SERVERPOD_DATABASE_REQUIRE_SSL: "false"
      SERVERPOD_REDIS_HOST: redis
      SERVERPOD_REDIS_PORT: "6379"
      SERVERPOD_REDIS_PASSWORD: ${REDIS_PASSWORD}
      SERVERPOD_SERVICE_SECRET: ${SERVICE_SECRET:?SERVICE_SECRET is required}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "8080:8080"   # API
      - "8081:8081"   # Insights (internal only — restrict in Nginx)
    networks:
      - backend
      - frontend

  # ── Nginx Reverse Proxy ──────────────────────────────────────────────────────
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - server
    networks:
      - frontend

volumes:
  postgres_data:

networks:
  backend:
    internal: true   # Postgres and Redis not accessible from outside
  frontend:
```

---

## 4. Nginx Configuration

```nginx
# nginx/nginx.conf
worker_processes auto;

events {
    worker_connections 4096;
}

http {
    # WebSocket upgrade map
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/m;

    upstream serverpod {
        server server:8080;
        keepalive 64;
    }

    # Redirect HTTP → HTTPS
    server {
        listen 80;
        server_name api.myapp.com;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name api.myapp.com;

        ssl_certificate     /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        # Security headers
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header Strict-Transport-Security "max-age=31536000" always;

        # API
        location / {
            limit_req zone=api burst=50 nodelay;

            proxy_pass http://serverpod;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # WebSocket support
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
        }

        # Auth endpoints — stricter rate limit
        location /serverpod_auth {
            limit_req zone=auth burst=10 nodelay;
            proxy_pass http://serverpod;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }
    }
}
```

---

## 5. Serverpod Production Config

```yaml
# config/production.yaml
apiServer:
  port: 8080
  publicHost: api.myapp.com
  publicPort: 443
  publicScheme: https

insightsServer:
  port: 8081
  publicHost: localhost     # Not exposed externally
  publicPort: 8081
  publicScheme: http

database:
  host: ${SERVERPOD_DATABASE_HOST}
  port: 5432
  name: ${SERVERPOD_DATABASE_NAME}
  user: ${SERVERPOD_DATABASE_USER}
  requireSsl: false           # SSL terminated by Nginx inside Docker network

redis:
  enabled: true
  host: ${SERVERPOD_REDIS_HOST}
  port: 6379
  requireSsl: false

logging:
  level: warning              # Only log warnings and errors in production
```

```
# .env (production — managed by secrets manager, NOT committed)
DB_NAME=myproject
DB_USER=myproject
DB_PASSWORD=<strong-random-password>
REDIS_PASSWORD=<strong-random-password>
SERVICE_SECRET=<64-char-random-hex>
```

---

## 6. Environment Variable Injection

Serverpod 3.4.x supports `${ENV_VAR}` substitution in config YAML files. Set the environment variables in your container orchestration system:

- **Docker Compose:** `.env` file or `environment:` block in `docker-compose.yml`
- **Kubernetes:** `Secret` objects mounted as env vars
- **AWS ECS:** Task definition secrets from AWS Secrets Manager
- **Fly.io:** `fly secrets set KEY=VALUE`

---

## 7. CI/CD Pipeline (GitHub Actions)

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Dart
        uses: dart-lang/setup-dart@v1
        with:
          sdk: stable

      - name: Get dependencies
        run: dart pub get
        working-directory: my_project_server

      - name: Analyze
        run: dart analyze
        working-directory: my_project_server

      - name: Run tests
        run: dart test
        working-directory: my_project_server

      - name: Build Docker image
        run: |
          docker build -t myapp-server:${{ github.sha }} ./my_project_server

      - name: Push to registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | docker login -u "${{ secrets.REGISTRY_USER }}" --password-stdin
          docker tag myapp-server:${{ github.sha }} registry.myapp.com/server:latest
          docker push registry.myapp.com/server:latest

      - name: Deploy (rolling restart)
        run: |
          ssh deploy@myserver "docker-compose pull server && docker-compose up -d --no-deps server"
```

---

## 8. PostgreSQL Configuration

```sql
-- scripts/init.sql — run once at cluster creation
-- Performance tuning for a 4 GB RAM server
ALTER SYSTEM SET shared_buffers = '1GB';
ALTER SYSTEM SET effective_cache_size = '3GB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET maintenance_work_mem = '256MB';
ALTER SYSTEM SET max_connections = 100;
ALTER SYSTEM SET wal_level = 'replica';   -- For backups
SELECT pg_reload_conf();
```

### Connection Pooling (PgBouncer)

For high-traffic deployments, add PgBouncer between Serverpod and PostgreSQL:

```yaml
# Add to docker-compose.yml
pgbouncer:
  image: pgbouncer/pgbouncer:latest
  environment:
    DATABASES_HOST: postgres
    DATABASES_PORT: "5432"
    DATABASES_DBNAME: myproject
    PGBOUNCER_POOL_MODE: transaction
    PGBOUNCER_MAX_CLIENT_CONN: "500"
    PGBOUNCER_DEFAULT_POOL_SIZE: "20"
  networks:
    - backend
```

Then point Serverpod's `database.host` to `pgbouncer` instead of `postgres`.

---

## 9. Database Backups

```bash
#!/bin/bash
# scripts/backup.sh — run via cron every 6 hours
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups"
DB_CONTAINER="myapp_postgres_1"

docker exec "$DB_CONTAINER" pg_dump -U myproject myproject \
    | gzip > "$BACKUP_DIR/myproject_$DATE.sql.gz"

# Keep last 30 days
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +30 -delete

# Optionally upload to S3
aws s3 cp "$BACKUP_DIR/myproject_$DATE.sql.gz" \
    "s3://myapp-backups/db/myproject_$DATE.sql.gz"
```

```
# Crontab entry
0 */6 * * * /app/scripts/backup.sh >> /var/log/backup.log 2>&1
```

---

## 10. Monitoring and Logging

### Serverpod Insights

Serverpod exposes the Insights dashboard on port 8081. **Restrict this to internal networks only** (handled by the Nginx config above).

Access via: `http://localhost:8081` when SSH-tunneled to the server.

### Log Aggregation

Serverpod writes structured logs to stdout. Forward them to a log aggregation service:

```yaml
# docker-compose.yml — add to server service
logging:
  driver: "json-file"
  options:
    max-size: "50m"
    max-file: "5"
    tag: "{{.Name}}"
```

For production, use **Loki + Grafana**, **Datadog**, or **CloudWatch Logs** to collect and query logs.

### Health Check Endpoint

```dart
// lib/src/endpoints/health_endpoint.dart
class HealthEndpoint extends Endpoint {
  Future<Map<String, dynamic>> check(Session session) async {
    return {
      'status': 'ok',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'version': '1.0.0',
    };
  }
}
```

---

## 11. Scaling Considerations

| Approach | When to use |
|----------|-------------|
| Vertical scaling | First step — increase CPU/RAM |
| Horizontal scaling | Multiple server containers behind load balancer |
| Read replicas | High read load — route reads to replica |
| Connection pooling (PgBouncer) | > 50 concurrent connections to PostgreSQL |
| Redis Cluster | > 100K pub/sub messages/second |
| CDN for file uploads | Serve static assets; offload bandwidth |

For horizontal scaling, ensure:
1. `redis.enabled: true` in production config (for session sharing and pub/sub).
2. Load balancer with WebSocket support (sticky sessions optional when using Redis).
3. All server instances share the same PostgreSQL and Redis.

---

## 12. Production Checklist

- [ ] HTTPS with TLS 1.2+ on all public endpoints
- [ ] Rate limiting on API and auth routes (Nginx `limit_req`)
- [ ] `passwords.yaml` / secrets never committed to git
- [ ] Strong, unique passwords for PostgreSQL, Redis, and `serviceSecret`
- [ ] `--apply-migrations` in server startup command
- [ ] Database backups scheduled and tested for restoration
- [ ] Health check endpoint responds correctly
- [ ] Insights dashboard restricted to internal network
- [ ] Log aggregation configured
- [ ] Monitoring alerts for error rate and latency
- [ ] Docker restart policy set to `unless-stopped`
- [ ] Non-root user in Dockerfile (`USER appuser`)
