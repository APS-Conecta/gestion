<?php
// SPDX-FileCopyrightText: 2026 APS Conecta
// SPDX-License-Identifier: AGPL-3.0-or-later
declare(strict_types=1);

// Replace only HTTP transport; exercise the real container API and Twig component.
namespace GuzzleHttp {
    class Client {
        public static array $image = [];
        public static ?string $remote = null;

        public function request(string $method, string $url, array $options = []): \Psr\Http\Message\ResponseInterface {
            if (str_contains($url, '/containers/')) {
                return new \GuzzleHttp\Psr7\Response(200, [], json_encode([
                    'Image' => 'sha256:fixture', 'State' => ['Running' => true],
                ]));
            }
            if (str_contains($url, '/images/')) {
                return new \GuzzleHttp\Psr7\Response(200, [], json_encode(self::$image));
            }
            if (str_starts_with($url, 'https://ghcr.io/token?')) {
                return new \GuzzleHttp\Psr7\Response(200, [], '{"token":"fixture"}');
            }
            if ($method === 'HEAD' && str_starts_with($url, 'https://ghcr.io/v2/')) {
                return new \GuzzleHttp\Psr7\Response(200, self::$remote === null ? [] : ['docker-content-digest' => self::$remote]);
            }
            throw new \RuntimeException('Unexpected HTTP request: ' . $method . ' ' . $url);
        }
    }
}
namespace {
    require getenv('AIO_TEST_AUTOLOAD') ?: __DIR__ . '/../vendor/autoload.php';
    // Load the tested checkout ahead of an installed image's autoloader.
    spl_autoload_register(function (string $name): void {
        if (str_starts_with($name, 'AIO\\')) {
            require __DIR__ . '/../src/' . str_replace('\\', '/', substr($name, 4)) . '.php';
        }
    }, true, true);
    $configuration = new \AIO\Data\ConfigurationManager();
    $manager = new \AIO\Docker\DockerActionManager($configuration,
        new \AIO\ContainerDefinitionFetcher($configuration, new \DI\Container()),
        new \AIO\Docker\DockerHubManager(), new \AIO\Docker\GitHubContainerRegistryManager());
    $container = new \AIO\Container\Container(
        'aps-conecta-nextcloud', 'Nextcloud', 'ghcr.io/aps-conecta/aio-nextcloud',
        'unless-stopped', 10, new \AIO\Container\ContainerPorts(), '',
        new \AIO\Container\ContainerVolumes(), new \AIO\Container\ContainerEnvironmentVariables(),
        [], '', [], false, [], [], 0, false, [], [], false, [], true, 'fixture',
        new \AIO\Container\AioVariables(), '', false, $manager);
    $twig = new \Twig\Environment(new \Twig\Loader\FilesystemLoader(__DIR__ . '/../templates'));
    $digest = 'sha256:' . str_repeat('a', 64);
    $other = 'sha256:' . str_repeat('b', 64);
    $cases = [
        'missing digests' => [[], $digest, 'unknown'],
        'empty digests' => [['RepoDigests' => []], $digest, 'unknown'],
        'malformed digests' => [['RepoDigests' => null], $digest, 'unknown'],
        'registry unavailable' => [['RepoDigests' => ['repo@' . $digest]], null, 'unknown'],
        'same digest' => [['RepoDigests' => ['repo@' . $digest]], $digest, 'equal'],
        'different digest' => [['RepoDigests' => ['repo@' . $digest]], $other, 'different'],
        'one matching digest' => [['RepoDigests' => ['repo@' . $other, 'repo@' . $digest]], $digest, 'equal'],
    ];
    foreach ($cases as $name => [$image, $remote, $expected]) {
        apcu_clear_cache();
        \GuzzleHttp\Client::$image = $image;
        \GuzzleHttp\Client::$remote = $remote;
        $state = $container->GetUpdateState()->value;
        if ($state !== $expected) {
            throw new \RuntimeException("$name: expected $expected, got $state");
        }
        $html = $twig->render('components/container-state.twig', ['c' => $container]);
        if (str_contains($html, 'Actualización&nbsp;disponible') !== ($expected === 'different')) {
            throw new \RuntimeException("$name: incorrect rendered update badge");
        }
        echo "PASS: $name\n";
    }
}
