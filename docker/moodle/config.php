<?php  // Moodle configuration file, driven entirely by environment variables.

// Every MOODLE_* variable can instead be supplied as MOODLE_*_FILE, pointing at
// a file that holds the value (Docker/Kubernetes secrets).
//
// Anything not covered here can be set by dropping PHP files into
// /etc/moodle/config.d/ (e.g. a Kubernetes ConfigMap); they are included in
// lexical order just before Moodle bootstraps and may use $CFG freely.

unset($CFG);
global $CFG;
$CFG = new stdClass();

$moodleenv = static function (string $name, $default = null) {
    $file = getenv($name . '_FILE');
    if ($file !== false && $file !== '') {
        if (!is_readable($file)) {
            throw new RuntimeException("{$name}_FILE points at unreadable file {$file}");
        }
        return rtrim(file_get_contents($file), "\r\n");
    }
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
};
$moodleenvbool = static function (string $name, bool $default = false) use ($moodleenv): bool {
    $value = $moodleenv($name);
    return $value === null ? $default : filter_var($value, FILTER_VALIDATE_BOOLEAN);
};

// Database.
$CFG->dbtype    = $moodleenv('MOODLE_DB_TYPE', 'mysqli'); // mysqli, mariadb, auroramysql, pgsql.
$CFG->dblibrary = 'native';
$CFG->dbhost    = $moodleenv('MOODLE_DB_HOST', 'db');
$CFG->dbname    = $moodleenv('MOODLE_DB_NAME', 'moodle');
$CFG->dbuser    = $moodleenv('MOODLE_DB_USER', 'moodle');
$CFG->dbpass    = $moodleenv('MOODLE_DB_PASSWORD', '');
$CFG->prefix    = $moodleenv('MOODLE_DB_PREFIX', 'mdl_');
$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => $moodleenv('MOODLE_DB_PORT', ''),
];
if (in_array($CFG->dbtype, ['mysqli', 'mariadb', 'auroramysql'], true)) {
    $CFG->dboptions['dbcollation'] = $moodleenv('MOODLE_DB_COLLATION', 'utf8mb4_unicode_ci');
    // 'require' or 'verify-full' (managed MySQL services generally require TLS).
    if ($ssl = $moodleenv('MOODLE_DB_SSL')) {
        $CFG->dboptions['ssl'] = $ssl;
    }
}

// Paths.
$CFG->wwwroot   = rtrim($moodleenv('MOODLE_WWWROOT', 'http://localhost:8080'), '/');
$CFG->dataroot  = $moodleenv('MOODLE_DATAROOT', '/var/www/moodledata');
$CFG->localcachedir = $moodleenv('MOODLE_LOCALCACHEDIR', '/var/cache/moodle'); // Per-container, not shared.
$CFG->admin     = 'admin';
$CFG->directorypermissions = 02770;

// Running behind a TLS-terminating reverse proxy / ingress.
$CFG->sslproxy     = $moodleenvbool('MOODLE_SSLPROXY');
$CFG->reverseproxy = $moodleenvbool('MOODLE_REVERSEPROXY');

// Apache sends unknown paths to r.php (FallbackResource), so the router works.
$CFG->routerconfigured = true;

// The code tree is immutable: plugins and core updates ship in the image.
$CFG->disableupdateautodeploy = true;
$CFG->disableupdatenotifications = true;
$CFG->preventexecpath = true;
$CFG->pathtogs  = '/usr/bin/gs';
$CFG->pathtodu  = '/usr/bin/du';
$CFG->pathtodot = '/usr/bin/dot';
$CFG->aspellpath = '/usr/bin/aspell';
$CFG->pathtopdftoppm = '/usr/bin/pdftoppm';

// Sessions in Redis/Valkey (required when running more than one web container).
if ($redishost = $moodleenv('MOODLE_REDIS_HOST')) {
    $CFG->session_handler_class = '\core\session\redis';
    $CFG->session_redis_host = $redishost;
    $CFG->session_redis_port = (int) $moodleenv('MOODLE_REDIS_PORT', 6379);
    $CFG->session_redis_database = (int) $moodleenv('MOODLE_REDIS_DB', 0);
    $CFG->session_redis_prefix = $moodleenv('MOODLE_REDIS_PREFIX', 'moodle_sess_');
    $CFG->session_redis_serializer_use_igbinary = true;
    if ($redisauth = $moodleenv('MOODLE_REDIS_PASSWORD')) {
        $CFG->session_redis_auth = $redisauth;
    }
    if ($moodleenvbool('MOODLE_REDIS_TLS')) {
        $CFG->session_redis_encrypt = [];
    }
}

// Outgoing mail. When unset these fall back to the values in Site administration.
if ($smtphosts = $moodleenv('MOODLE_SMTP_HOSTS')) {
    $CFG->smtphosts  = $smtphosts; // host:port[;host:port]
    $CFG->smtpsecure = $moodleenv('MOODLE_SMTP_SECURE', 'tls'); // '', 'ssl', 'tls'
    $CFG->smtpauthtype = $moodleenv('MOODLE_SMTP_AUTHTYPE', 'LOGIN');
    $CFG->smtpuser   = $moodleenv('MOODLE_SMTP_USER', '');
    $CFG->smtppass   = $moodleenv('MOODLE_SMTP_PASSWORD', '');
}
if ($noreply = $moodleenv('MOODLE_NOREPLY_ADDRESS')) {
    $CFG->noreplyaddress = $noreply;
}

if ($moodleenvbool('MOODLE_DEBUG')) {
    $CFG->debug = E_ALL; // DEBUG_DEVELOPER.
    $CFG->debugdisplay = 1;
}

foreach (glob('/etc/moodle/config.d/*.php') ?: [] as $moodleconfigfile) {
    require $moodleconfigfile;
}
unset($moodleenv, $moodleenvbool, $moodleconfigfile, $ssl, $redishost, $redisauth, $smtphosts, $noreply);

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
