# Plugins

Third-party Moodle plugins baked into the image. Lay them out exactly as they
sit under the Moodle web root, e.g.:

```
plugins/auth/vatusa/version.php   -> <webroot>/auth/vatusa/version.php
plugins/theme/academy/version.php -> <webroot>/theme/academy/version.php
```

`<webroot>` is `public/` for Moodle 5.1+ and the code root for earlier
versions; the Dockerfile picks the right one. After adding or updating a
plugin, rebuild the image and run `moodle-bootstrap` to apply its DB upgrade.
