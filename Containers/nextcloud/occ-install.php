<?php
// SPDX-FileCopyrightText: 2026 APS Conecta
// SPDX-License-Identifier: AGPL-3.0-or-later

declare(strict_types=1);

try {
    $secrets = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
    if (($argv[2] ?? null) !== 'maintenance:install' || !is_array($secrets) || count($secrets) !== 2) {
        throw new InvalidArgumentException();
    }
    $argv = array_slice($argv, 1);
    foreach (['admin-pass', 'database-pass'] as $name) {
        if (!is_string($secrets[$name] ?? null) || $secrets[$name] === '') {
            throw new InvalidArgumentException();
        }
        $argv[] = '--' . $name . '=' . $secrets[$name];
    }
} catch (Throwable) {
    fwrite(STDERR, "Invalid installation credentials.\n");
    exit(1);
}

$argc = count($argv);
$_SERVER['argv'] = $argv;
$_SERVER['argc'] = $argc;
require $argv[0];
