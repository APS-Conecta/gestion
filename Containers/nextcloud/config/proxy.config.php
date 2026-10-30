<?php
// SPDX-FileCopyrightText: 2026 APS Conecta
// SPDX-License-Identifier: AGPL-3.0-or-later

if (getenv('HTTP_PROXY')) {
    $CONFIG['proxy'] = getenv('HTTP_PROXY');
}
if (getenv('HTTPS_PROXY')) {
    $CONFIG['proxy'] = getenv('HTTPS_PROXY');
}
if (isset($CONFIG['proxy'])) {
    $CONFIG['proxyuserpwd'] = getenv('PROXY_USER_PASSWORD') ?: '';
    $CONFIG['config_extra_sensitive_values'] = ['proxy' => true];
}
if (getenv('NO_PROXY')) {
    $CONFIG['proxyexclude'] = explode(',', getenv('NO_PROXY'));
}
