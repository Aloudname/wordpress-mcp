<?php
/**
 * 创建/复用 MCP 专用 WordPress 用户并签发应用密码。
 *
 * 用法(在 WordPress 主机上,以能读 wp-load.php 的用户执行):
 *   php setup-wp-user.php <username> <app-name>
 *
 * 输出(供 install.sh 解析):
 *   user_id=<id>
 *   app_password=<明文密码,仅本次可见>
 *
 * 幂等:用户已存在则复用;每次运行都会新签一个应用密码
 * (旧密码可在 WP 后台「用户 -> 应用程序密码」撤销)。
 */

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "仅限命令行运行\n");
    exit(1);
}

$username = $argv[1] ?? 'mcp_agent';
$app_name = $argv[2] ?? 'wordpress-mcp';

// 第三参数显式指定 wp-load.php(install.sh 会传),否则自动探测
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
