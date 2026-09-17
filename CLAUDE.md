# CLAUDE.md

Production container image for Moodle LMS. It is deployed first with Docker Compose
on a VPS behind a host-installed Caddy (`deploy/`); Kubernetes via `gitops` may come
later. `README.md` is the user-facing reference
(env vars, build args, requirements); keep it in sync with any behavior change.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-stage: `base` (PHP + extensions/tools), `build` (Moodle tarball + composer + plugins), `runtime` |
| `docker/moodle/config.php` | The only `config.php`; builds `$CFG` from `MOODLE_*` env vars (each also accepts `MOODLE_*_FILE`) and includes `/etc/moodle/config.d/*.php` |
| `docker/php/moodle.ini` | PHP settings; `${PHP_*}` values come from `ENV` defaults in the Dockerfile |
| `docker/apache/moodle.conf` | Router fallback, internal-file 404 blocks, logging to stdout/stderr, `/healthz` |
| `docker/bin/moodle-bootstrap` | Install into an empty DB or apply pending upgrade (one-shot job) |
| `docker/bin/moodle-cron` | Long-running cron loop |
| `plugins/` | Third-party plugins, laid out like the Moodle web root |
| `docker-compose.yml` | Local test stack only (hardcoded passwords, plain HTTP) |
| `deploy/` | Production Compose stack for a VPS: `compose.yaml`, `.env.example`, `init-secrets.sh`, `Caddyfile.example`, `backup.sh` |

## Commands

```sh
docker build -t vatusa/moodle:local .                  # build (default Moodle/PHP versions)
docker compose up -d --build                           # full local stack, http://localhost:8080, admin / Admin-1234!
docker compose logs -f bootstrap                       # install/upgrade output
docker compose exec web php admin/cli/checks.php       # Moodle status checks
docker compose exec web php admin/cli/environment.php  # requirement check for this release
docker compose down -v                                 # tear down, including DB and moodledata volumes
```

There is no test suite; verify changes by building and running the compose stack
(bootstrap exits 0, `/healthz` and `/login/index.php` return 200, admin login works).

To test `deploy/` without touching the dev stack, copy the repo to a scratch dir, set
`MOODLE_DOMAIN=localhost:18443` and `MOODLE_HTTP_BIND=127.0.0.1:18080` in `.env`, run
with `COMPOSE_PROJECT_NAME=moodle-prodtest`, and stand in for the host Caddy with
`docker run --network host caddy:2.10` using a `localhost:18443` site block. Moodle
redirects any request whose host doesn't match `wwwroot`, so test through Caddy.

## Design rules

- Code is immutable: owned by root in `/var/www/moodle`, served from `public/`
  (Moodle 5.1+) via the `/var/www/html` symlink. Never add runtime code writes,
  web-based plugin installs, or startup-time config generation.
- Container runs as `www-data` on port 8080. Only `/var/www/moodledata` and
  `/var/cache/moodle` are writable.
- One image, three roles selected by command: `apache2-foreground` (default),
  `moodle-cron`, `moodle-bootstrap`. Compose disables the image HEALTHCHECK for
  the latter two since they don't serve HTTP.
- New configuration goes into `config.php` as an env var (with a sane default)
  and gets a row in the README's env var table.
- `deploy/` assumes Caddy on the host is the only entry point: web binds to loopback,
  `MOODLE_SSLPROXY` and `MOODLE_TRUST_X_FORWARDED_FOR` are on. Don't publish web
  publicly or put Caddy in the compose file.
- Secrets in `deploy/` are Docker secrets files read via `*_FILE`; the files must be
  world-readable (containers run as www-data/mysql), protected by the 0700 directory.
- Plugins are added to `plugins/` at build time; after adding one, rebuild and run
  `moodle-bootstrap`.

## Moodle versions

- Default is the latest stable release (`MOODLE_VERSION` build arg, a GitHub tag).
  Moodle 5.3 LTS is due 2026-10-05.
- When changing versions, check requirements in that release's
  `public/admin/environment.xml` (PHP range, extensions, DB minimums) and adjust
  `PHP_VERSION`, the extension list, and the build-time extension check in the
  Dockerfile's `base` stage. Moodle 5.2 needs PHP 8.3–8.4 and MySQL ≥ 8.4.
- docs.moodle.org blocks automated fetches (Cloudflare challenge); read the Moodle
  source (`environment.xml`, `config-dist.php`, `admin/cli/*`) or moodledev.io instead.
- The Dockerfile still handles pre-5.1 layouts (no `public/`, committed `vendor/`),
  so older tags build with a matching `PHP_VERSION`.

## Known quirks

- `admin/cli/checks.php --type=security` often crashes with `Class "curl" not found`.
  This is a Moodle CLI issue, not a missing extension; PHP's curl is loaded.
- `lib/setup.php` at the code root is a shim on 5.1+, so `config.php`'s
  `require_once(__DIR__ . '/lib/setup.php')` works for all versions.
