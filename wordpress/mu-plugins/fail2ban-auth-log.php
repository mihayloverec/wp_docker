<?php
/**
 * Plugin Name:  fail2ban auth logger
 * Description:  Appends failed WordPress logins to a file fail2ban watches.
 *               No settings, no admin UI, no database writes.
 *
 * WHY THIS EXISTS
 * A failed WordPress login is an HTTP 200 POST to wp-login.php — byte for byte
 * indistinguishable from a successful one in Apache's access log. So a jail
 * built on web-server logs can only rate-limit *all* requests to wp-login.php,
 * which punishes legitimate users on shared IPs. Only WordPress knows a login
 * actually failed, and `wp_login_failed` is where it says so.
 *
 * WHY REMOTE_ADDR AND NOT X-Forwarded-For
 * Apache has already rewritten REMOTE_ADDR from X-Forwarded-For via
 * mod_remoteip, and ONLY for requests arriving from TRUSTED_PROXY_CIDRS
 * (apache/hardening.conf). Reading the header directly here would let anyone
 * put an arbitrary address in this log and have a third party banned — turning
 * the protection into an attack. So: never trust the header, always REMOTE_ADDR.
 *
 * This file is bind-mounted read-only, so it cannot be modified from inside
 * WordPress even if an admin account is compromised.
 */

if (!defined('ABSPATH')) {
    exit;
}

if (!defined('WP_F2B_LOG')) {
    define('WP_F2B_LOG', '/var/log/wp/auth.log');
}
// Poor-man's rotation ceiling. The container log is capped by the logging
// driver; this file is not, so it needs its own bound or it grows forever
// under a sustained attack — exactly when you can least afford a full disk.
if (!defined('WP_F2B_MAX_BYTES')) {
    define('WP_F2B_MAX_BYTES', 5 * 1024 * 1024);
}

/**
 * Append one event line. Format is stable and parsed by
 * fail2ban/filter.d/wordpress-auth.conf — change one, change the other.
 */
function wp_f2b_write($event, $detail = '') {
    $ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    if ($ip === '' || filter_var($ip, FILTER_VALIDATE_IP) === false) {
        return;
    }

    // Keep user-supplied text on one line and free of quotes so a crafted
    // username cannot forge extra log lines (and thus a ban for someone else).
    $detail = preg_replace('/[^A-Za-z0-9@._\- ]/', '', (string) $detail);
    $detail = substr($detail, 0, 64);

    // MICROSECONDS ARE LOAD-BEARING. fail2ban collapses failures that share a
    // timestamp, so with one-second resolution six attempts inside the same
    // second counted as ONE — a fast password-guessing script was undercounted
    // precisely because it was fast, which is backwards. Measured: 6 attempts
    // in one second -> 1 failure registered; the same 6 spread over 6 seconds
    // -> banned correctly. Sub-second resolution is what makes rapid attempts
    // count individually. Keep this in sync with `datepattern` in
    // fail2ban/filter.d/wordpress-auth.conf.
    $mt = microtime(true);
    $sec = (int) $mt;
    $usec = (int) round(($mt - $sec) * 1000000);
    if ($usec >= 1000000) {   // rounding can push it over a second boundary
        $sec++;
        $usec = 0;
    }

    $line = sprintf(
        "%s.%06dZ wp-auth ip=%s event=%s user=%s\n",
        gmdate('Y-m-d\TH:i:s', $sec),
        $usec,
        $ip,
        $event,
        $detail === '' ? '-' : $detail
    );

    if (@filesize(WP_F2B_LOG) > WP_F2B_MAX_BYTES) {
        @rename(WP_F2B_LOG, WP_F2B_LOG . '.1');
    }
    @file_put_contents(WP_F2B_LOG, $line, FILE_APPEND | LOCK_EX);
}

// The event fail2ban counts.
add_action('wp_login_failed', function ($username) {
    wp_f2b_write('login-failed', $username);
}, 10, 1);

// A rejected XML-RPC authentication. xmlrpc.php is denied in
// apache/hardening.conf by default, so this only fires if that block was
// commented out (Jetpack / the mobile app) — where brute force via
// system.multicall is precisely the risk worth logging.
add_action('xmlrpc_login_error', function ($error, $user) {
    $name = is_wp_error($user) ? '' : (isset($user->user_login) ? $user->user_login : '');
    wp_f2b_write('xmlrpc-auth-failed', $name);
}, 10, 2);
