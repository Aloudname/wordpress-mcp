<?php
/**
 * create (or reuse) the dedicated mcp wordpress user and issue an
 * application password.
 *
 * usage (run on the wordpress host as a user that can read wp-load.php):
 *   php setup-wp-user.php <username> <app-name> [wp-load.php path]
 *
 * output (parsed by install.sh):
 *   user_id=<id>
 *   app_password=<plaintext, shown once>
 *
 * idempotent: an existing user is reused. every run issues a new app
 * password (revoke old ones in wp admin -> users -> application passwords).
 */

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "仅限命令行运行\n");
    exit(1);
}

$username = $argv[1] ?? 'mcp_agent';
$app_name = $argv[2] ?? 'wordpress-mcp';

// argv[3] takes an explicit wp-load.php path (install.sh passes it);
// fall back to auto-detection
$wp_load = $argv[3] ?? null;
if (!$wp_load || !is_file($wp_load)) {
    foreach ([__DIR__ . '/../../../wp-load.php', '/var/www/wordpress/wp-load.php'] as $candidate) {
        if (is_file($candidate)) { $wp_load = $candidate; break; }
    }
}
if (!$wp_load || !is_file($wp_load)) {
    fwrite(STDERR, "找不到 wp-load.php,请作为第三参数传入\n");
    exit(1);
}
require $wp_load;

$user = get_user_by('login', $username);
if (!$user) {
    $uid = wp_create_user($username, wp_generate_password(24, true, true), $username . '@localhost');
    if (is_wp_error($uid)) {
        fwrite(STDERR, 'create user failed: ' . $uid->get_error_message() . PHP_EOL);
        exit(1);
    }
    $u = new WP_User($uid);
    $u->set_role('editor');
    echo 'user_id=' . $uid . PHP_EOL;
} else {
    $uid = $user->ID;
    echo 'user_id=' . $uid . PHP_EOL;
}

list($pw, $item) = WP_Application_Passwords::create_new_application_password($uid, ['name' => $app_name]);
if (is_wp_error($pw)) {
    fwrite(STDERR, 'app password failed: ' . $pw->get_error_message() . PHP_EOL);
    exit(1);
}
echo 'app_password=' . $pw . PHP_EOL;
