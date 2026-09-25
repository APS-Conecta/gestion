<?php
// OCP stub surface for the desktop_workspace pin seat (gestion/tests/desktop_workspace/).
// There is no Nextcloud server here: these interfaces are the ONLY definitions, so they
// carry exactly the methods the code under test calls — nothing more. Registered by
// settings-controller.test.php's autoloader before the patched app files load.
namespace OCP {
    interface IConfig {
        public function getAppValue(string $appName, string $key, string $default = ''): string;
        public function setAppValue(string $appName, string $key, string $value): void;
        public function getUserValue(string $userId, string $appName, string $key, string $default = ''): string;
        public function setUserValue(string $userId, string $appName, string $key, string $value): void;
        public function deleteUserValue(string $userId, string $appName, string $key): void;
        /** @return string[] */
        public function getUserKeys(string $userId, string $appName): array;
    }
    interface IUserSession {
        public function getUser(): ?\OCP\IUser;
    }
    interface IUserManager {
        public function get(string $userId): ?\OCP\IUser;
    }
    interface IUser {
        public function getUID(): string;
    }
    interface IRequest {
        public function getParam(string $key, string $default = ''): string;
    }
    interface IDBConnection {
        public function getQueryBuilder(): \OCP\DB\IQueryBuilder;
    }
    interface ICacheFactory {
        public function isAvailable(): bool;
        public function createDistributed(string $ns): \OCP\ICache;
    }
    interface ICache {
        public function get(string $key): mixed;
        public function set(string $key, mixed $value, int $ttl = 0): bool;
    }
    interface IStorage {
        public function instanceOfStorage(string $class): bool;
        public function getId(): string;
    }
}

namespace OCP\DB {
    interface IQueryBuilder {
        public function insert(string $table): \OCP\DB\IQueryBuilder;
        /** @param array<string,mixed> $values */
        public function values(array $values): \OCP\DB\IQueryBuilder;
        public function createNamedParameter(mixed $value): mixed;
        public function executeStatement(): int;
    }
}

namespace OCP\AppFramework {
    class Controller {
        public function __construct(protected string $appName, protected \OCP\IRequest $request) {
        }
    }
}

namespace OCP\AppFramework\Http\Attribute {
    #[\Attribute]
    final class NoAdminRequired {
    }
}

namespace OCP\AppFramework\Http {
    class JSONResponse {
        public function __construct(private mixed $data = [], private int $status = 200) {
        }
        public function getData(): mixed { return $this->data; }
        public function getStatus(): int { return $this->status; }
    }
}

namespace OCP\Files {
    interface IMountPoint {
        public function getMountType(): string;
    }
    interface INode {
        public function getPath(): string;
        public function getRelativePath(string $path): ?string;
        public function getStorage(): \OCP\IStorage;
        public function getMountPoint(): \OCP\Files\IMountPoint;
        public function getOwner(): ?\OCP\IUser;
    }
    interface Folder extends INode {
        public function get(string $path): \OCP\Files\INode;
    }
    interface IRootFolder extends Folder {
        public function getUserFolder(string $userId): \OCP\Files\Folder;
    }
    class NotFoundException extends \Exception {
    }
}

namespace OC\DB\Exceptions {
    class DbalException extends \Exception {
        public function __construct(string $message = '', int $code = 0) {
            parent::__construct($message, $code);
        }
    }
}
