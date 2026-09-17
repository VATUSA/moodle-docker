# moodle-docker

Production container image for [Moodle LMS](https://moodle.org), designed to
deploy to Kubernetes through `gitops`.

The default build is **Moodle 5.2.3 on PHP 8.4 (Debian trixie, Apache + mod_php)**.

```sh
docker compose up -d --build   # MySQL 8.4 + Valkey + Moodle web + cron
open http://localhost:8080     # admin / Admin-1234!
```

## How the image works

One image does three jobs. You pick the job with the container command:

| Command                        | Job                                                                 |
|--------------------------------|---------------------------------------------------------------------|
| `apache2-foreground` (default) | Web server on port **8080**, running as `www-data`                  |
| `moodle-cron`                  | Long-running cron worker (`admin/cli/cron.php --keep-alive`, in a loop) |
| `moodle-bootstrap`             | Installs Moodle into an empty DB, or applies any pending upgrade, then exits |

- **Code is part of the image and can't be changed at runtime.** It lives in
  `/var/www/moodle` and belongs to root. Apache serves `public/` (Moodle 5.1+).
  Installing or updating plugins from the web UI is turned off. Plugins go in
  `plugins/` and ship with the image (see `plugins/README.md`).
- **Configuration comes from environment variables.** `docker/moodle/config.php`
  reads them, so no `config.php` gets generated. For anything that file doesn't
  cover, mount PHP files into `/etc/moodle/config.d/` (for example, a ConfigMap).
- **State** is the database plus `/var/www/moodledata`. With more than one web
  replica, moodledata must be on shared storage (RWX), and sessions must use
  Redis/Valkey. `localcachedir` stays inside each container (`/var/cache/moodle`).
- **Moodle's router works out of the box.** Apache sends unknown paths to
  `r.php` (`FallbackResource`), and `$CFG->routerconfigured = true` is set.
- Internal files are blocked with 404s, following the MDL-69333 list: `vendor/`,
  `composer.json`, `db/install.xml`, `fixtures/`, dotfiles, and so on.
- `GET /healthz` is a static liveness check that doesn't touch PHP or the database.

### Environment variables

| Variable | Default | Notes |
|---|---|---|
| `MOODLE_WWWROOT` | `http://localhost:8080` | Public URL, no trailing slash |
| `MOODLE_DB_TYPE` | `mysqli` | `mysqli`, `mariadb`, `auroramysql`, `pgsql` |
| `MOODLE_DB_HOST` / `_PORT` / `_NAME` / `_USER` / `_PASSWORD` | `db` / default / `moodle` / `moodle` / – | |
| `MOODLE_DB_PREFIX` | `mdl_` | Max 10 chars |
| `MOODLE_DB_COLLATION` | `utf8mb4_unicode_ci` | MySQL/MariaDB only |
| `MOODLE_DB_SSL` | – | `require` or `verify-full` (DO managed MySQL needs TLS) |
| `MOODLE_SSLPROXY` | `false` | Set to `true` behind a TLS-terminating ingress |
| `MOODLE_REVERSEPROXY` | `false` | |
| `MOODLE_REDIS_HOST` / `_PORT` / `_DB` / `_PASSWORD` / `_PREFIX` / `_TLS` | – | Setting the host turns on Redis sessions |
| `MOODLE_SMTP_HOSTS` / `_SECURE` / `_AUTHTYPE` / `_USER` / `_PASSWORD` | – | Forces SMTP settings; otherwise they're set in the admin UI |
| `MOODLE_NOREPLY_ADDRESS` | – | |
| `MOODLE_DEBUG` | `false` | Developer debugging, shown on the page |
| `PHP_MEMORY_LIMIT` | `512M` | Other PHP limits: `PHP_UPLOAD_MAX_FILESIZE`, `PHP_POST_MAX_SIZE`, `PHP_MAX_EXECUTION_TIME`, `PHP_OPCACHE_MEMORY`, `PHP_TIMEZONE` |
| `MOODLE_CRON_KEEPALIVE` | `300` | `moodle-cron`: seconds each cron.php run keeps polling |
| `MOODLE_ADMIN_PASSWORD` | – | `moodle-bootstrap`: required for a first install. Also `MOODLE_ADMIN_USER`, `MOODLE_ADMIN_EMAIL`, `MOODLE_SITE_FULLNAME`, `MOODLE_SITE_SHORTNAME`, `MOODLE_LANG`, `MOODLE_SUPPORT_EMAIL` |

Any `MOODLE_*` variable can also be passed as `MOODLE_*_FILE`, a path to a
file that holds the value.

### Build arguments

| Arg | Default | |
|---|---|---|
| `MOODLE_VERSION` | `v5.2.3` | Any tag from github.com/moodle/moodle |
| `MOODLE_SHA256` | – | Checks the release tarball when set |
| `PHP_VERSION` | `8.4` | Must be in the range the chosen Moodle release supports |
| `DEBIAN_RELEASE` | `trixie` | |

## Requirements this image meets

These come from `public/admin/environment.xml` in Moodle 5.2.3:

- PHP ≥ 8.3 (64-bit). 8.4 is supported.
- Required extensions: iconv, mbstring, curl, openssl, ctype, zip, zlib, gd,
  simplexml, spl, pcre, dom, xml, xmlreader, intl, json, hash, fileinfo,
  sodium, filter.
- Optional extensions: exif, soap, tokenizer.
- The image also adds: mysqli, pgsql, opcache, apcu, igbinary, redis.
- `max_input_vars >= 5000`, `memory_limit >= 96M`, OPcache on,
  `zend.exception_ignore_args` on.
- Dependencies installed with `composer install --no-dev --classmap-authoritative`.
  Moodle 5.1+ no longer commits `vendor/`.
- Web root is `public/`, with the router configured.
- Database: **MySQL ≥ 8.4**, MariaDB ≥ 10.11, PostgreSQL ≥ 16, or Aurora MySQL 8.0.
- Tools used from `config.php`: ghostscript, pdftoppm, graphviz, aspell,
  plus the `en_AU.UTF-8` locale that the `en` language pack needs.

With this image, Moodle's own environment check passes with no failures, and
the `admin/cli/checks.php` status and performance checks all come back OK.

## Staying current

Moodle ships a minor release (5.2.x) roughly every two months. Bump the
`MOODLE_VERSION` default, rebuild, and run `moodle-bootstrap` to apply the
upgrade. Moodle 5.3 (LTS) is due 2026-10-05. It needs its own requirements
check against `public/admin/environment.xml` before switching.

## Prior art

- [moodlehq/moodle-php-apache](https://github.com/moodlehq/moodle-php-apache):
  Moodle HQ's PHP/Apache base image for development and CI. The extension set
  and the `FallbackResource /r.php` router setup came from here. It ships no
  Moodle code and includes dev tools (xdebug, pcov, sqlsrv).
- [moodlehq/moodle-docker](https://github.com/moodlehq/moodle-docker): a
  development and test environment (mounts a local checkout). Not meant for production.
- [erseco/alpine-moodle](https://github.com/erseco/alpine-moodle): community
  production image (Alpine, nginx + php-fpm). It generates `config.php` and
  syncs code into a volume when the container starts. This image keeps
  code in the image and reads config from environment variables instead.
- Bitnami `bitnami/moodle` was moved to the unmaintained `bitnamilegacy` repo
  in August 2025, so it isn't an option anymore.
