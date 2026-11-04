import { test, expect } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs'
import { createPrivateKey, sign } from 'node:crypto'
import { request } from 'node:http'
import { logInToContainersPage } from './helpers.js';

test('Initial setup', async ({ page: setupPage, browser }) => {
  test.setTimeout(10 * 60 * 1000)

  const containersPage = await logInToContainersPage(setupPage);

  // Reject IP addresses
  await containersPage.locator('#domain').click();
  await containersPage.locator('#domain').fill('1.1.1.1');
  await containersPage.getByRole('button', { name: 'Enviar dominio' }).click();
  await expect(containersPage.locator('body')).toContainText('¡Ingrese un dominio y no una dirección IP!');

  // Accept example.com (requires disabled domain validation)
  await containersPage.locator('#domain').click();
  await containersPage.locator('#domain').fill('example.com');
  await containersPage.getByRole('button', { name: 'Enviar dominio' }).click();

  // Disable all additional containers
  await containersPage.locator('#talk').uncheck();
  await containersPage.getByRole('checkbox', { name: 'Whiteboard' }).uncheck();
  await containersPage.getByRole('checkbox', { name: 'Imaginary' }).uncheck();
  await containersPage.getByText('Desactivar la suite de oficina').click();
  await containersPage.getByRole('button', { name: 'Guardar cambios' }).last().click();
  await expect(containersPage.locator('#talk')).not.toBeChecked()
  await expect(containersPage.getByRole('checkbox', { name: 'Whiteboard' })).not.toBeChecked()
  await expect(containersPage.getByRole('checkbox', { name: 'Imaginary' })).not.toBeChecked()
  await expect(containersPage.locator('#office-none')).toBeChecked()

  // Reject invalid time zones
  await containersPage.locator('#timezone').click();
  await containersPage.locator('#timezone').fill('Invalid time zone');
  containersPage.once('dialog', dialog => {
    dialog.accept()
  });
  await containersPage.getByRole('button', { name: 'Enviar la zona horaria' }).click();
  await expect(containersPage.locator('body')).toContainText('¡La zona horaria ingresada no parece ser válida!')

  // Accept valid time zone
  await containersPage.locator('#timezone').click();
  await containersPage.locator('#timezone').fill('Europe/Berlin');
  containersPage.once('dialog', dialog => {
    dialog.accept()
  });
  await containersPage.getByRole('button', { name: 'Enviar la zona horaria' }).click();

  // Start containers and wait for starting message
  await containersPage.getByRole('button', { name: 'Descargar e iniciar contenedores' }).click();
  await expect(containersPage.getByRole('main')).toContainText('Los contenedores se están iniciando.', { timeout: 5 * 60 * 1000 });
  await expect(containersPage.getByRole('link', { name: 'Abrir APS Conecta Gestión ↗' })).toBeVisible({ timeout: 3 * 60 * 1000 });
  await expect(containersPage.getByRole('link', { name: 'Abrir APS Conecta Gestión ↗' })).toHaveAttribute('href', 'https://example.com');

  // While Nextcloud is running, the direct login is blocked...
  const blockedPage = await (await browser.newContext()).newPage();
  await blockedPage.goto('./login');
  await expect(blockedPage.locator('body')).toContainText('El inicio de sesión directo está bloqueado porque APS Conecta Gestión está en ejecución.');
  await expect(blockedPage.locator('#master-password')).toHaveCount(0);

  // Extract initial nextcloud password
  await expect(containersPage.getByRole('main')).toContainText('Contraseña inicial de APS Conecta Gestión:')
  const initialNextcloudPassword = await containersPage.locator('#initial-nextcloud-password').innerText();

  // Reject backup location with relative path segments
  await containersPage.locator('#borg_backup_host_location').click();
  await containersPage.locator('#borg_backup_host_location').fill('/tmp/test/../aio');
  await containersPage.getByRole('button', { name: 'Enviar la ubicación de la copia de seguridad' }).click();
  await expect(containersPage.locator('body')).toContainText("no debe contener '//', '/./', '/../' ni '/,/'");

  // Reject backup location with '/,/'
  await containersPage.locator('#borg_backup_host_location').click();
  await containersPage.locator('#borg_backup_host_location').fill('/tmp/test/,/aio');
  await containersPage.getByRole('button', { name: 'Enviar la ubicación de la copia de seguridad' }).click();
  await expect(containersPage.locator('body')).toContainText("no debe contener '//', '/./', '/../' ni '/,/'");

  // Reject backup location inside /var/lib/docker
  await containersPage.locator('#borg_backup_host_location').click();
  await containersPage.locator('#borg_backup_host_location').fill('/var/lib/docker/volumes/aio');
  await containersPage.getByRole('button', { name: 'Enviar la ubicación de la copia de seguridad' }).click();
  await expect(containersPage.locator('body')).toContainText("Use en su lugar el nombre de volumen de Docker 'nextcloud_aio_backupdir'.");

  // Reject backup location inside a system directory
  await containersPage.locator('#borg_backup_host_location').click();
  await containersPage.locator('#borg_backup_host_location').fill('/etc/aio');
  await containersPage.getByRole('button', { name: 'Enviar la ubicación de la copia de seguridad' }).click();
  await expect(containersPage.locator('body')).toContainText("no debe estar dentro del directorio del sistema '/etc'");

  // Set backup location and create backup
  const borgBackupLocation = `/tmp/test/aio-${Math.floor(Math.random() * 2147483647)}`
  await containersPage.locator('#borg_backup_host_location').click();
  await containersPage.locator('#borg_backup_host_location').fill(borgBackupLocation);
  await containersPage.getByRole('button', { name: 'Enviar la ubicación de la copia de seguridad' }).click();
  await expect(containersPage.locator('#borg-backup-password')).toBeVisible();
  containersPage.once('dialog', dialog => {
    dialog.accept()
  });
  await containersPage.getByRole('button', { name: 'Crear copia de seguridad' }).click();
  await expect(containersPage.getByRole('main')).toContainText('El contenedor de copias de seguridad está en ejecución:', { timeout: 3 * 60 * 1000 });
  await expect(containersPage.getByRole('main')).toContainText('¡La última copia de seguridad fue exitosa el', { timeout: 3 * 60 * 1000 });
  await containersPage.getByText('Haga clic aquí para mostrar todas las opciones de copia de seguridad').click();
  await containersPage.getByText('Mostrar su contraseña de cifrado de las copias de seguridad').click();
  await expect(containersPage.locator('#borg-backup-password')).toBeVisible();
  const borgBackupPassword = await containersPage.locator('#borg-backup-password').innerText();

  // Assert that all containers are stopped
  await expect(containersPage.getByRole('button', { name: 'Iniciar contenedores' })).toBeVisible();

  // Save passwords for restore backup test
  writeFileSync('test_data.json', JSON.stringify({
    initialNextcloudPassword,
    borgBackupLocation,
    borgBackupPassword,
  }))
});

test('Log in via token-unblocked login form', async ({ page: containersPage, browser }) => {
  test.setTimeout(10 * 60 * 1000)

  const readConfig = () => JSON.parse(readFileSync('/mnt/docker-aio-config/data/configuration.json', 'utf8'));
  const { password } = readConfig();

  // The previous test left the containers stopped, so the direct login is allowed
  await containersPage.goto('./login');
  await containersPage.locator('#master-password').fill(password);
  await containersPage.getByRole('button', { name: 'Iniciar sesión' }).click();
  await containersPage.waitForURL('./containers');

  // Start containers so that the direct login gets blocked
  await containersPage.getByRole('button', { name: 'Iniciar contenedores' }).click();
  await expect(containersPage.getByRole('link', { name: 'Abrir APS Conecta Gestión ↗' })).toBeVisible({ timeout: 5 * 60 * 1000 });

  // After logging out, the login form is blocked
  await containersPage.getByRole('button', { name: 'Cerrar sesión' }).click();
  await containersPage.waitForURL('./login');
  await expect(containersPage.locator('body')).toContainText('El inicio de sesión directo está bloqueado porque APS Conecta Gestión está en ejecución.');
  await expect(containersPage.locator('#master-password')).toHaveCount(0);

  // Starting the containers generates a new token, so read it only now
  const { AIO_TOKEN } = readConfig();
  const tokenPage = await (await browser.newContext()).newPage();
  await tokenPage.goto(`./api/auth/getlogin?token=${AIO_TOKEN}`);
  await expect(tokenPage).toHaveURL(/\/login$/);
  await expect(tokenPage.locator('body')).toContainText('Este formulario de inicio de sesión está disponible para usted durante un máximo de 5 minutos y 5 intentos.');
  await expect(tokenPage.locator('#master-password')).toBeVisible();
  await tokenPage.locator('#master-password').fill(password);
  await tokenPage.getByRole('button', { name: 'Iniciar sesión' }).click();
  await tokenPage.waitForURL('./containers');
  await expect(tokenPage.getByRole('link', { name: 'Abrir APS Conecta Gestión ↗' })).toBeVisible();

  // A signature made with the private key that was handed to the Nextcloud container unblocks the login form
  const signaturePage = await (await browser.newContext()).newPage();
  // Check that the login is blocked.
  await signaturePage.goto('./login');
  await expect(signaturePage.locator('body')).toContainText('El inicio de sesión directo está bloqueado porque APS Conecta Gestión está en ejecución.');
  await expect(signaturePage.locator('#master-password')).toHaveCount(0);
  // Check that a request to the API with a valid signature redirects to the unblocked login.
  await signaturePage.goto(`./api/auth/getlogin?signature=${signTimestamp(await getUnblockLoginPrivateKey())}`);
  await expect(signaturePage).toHaveURL(/\/login$/);
  await expect(signaturePage.locator('body')).toContainText('Este formulario de inicio de sesión está disponible para usted durante un máximo de 5 minutos y 5 intentos.');
  await expect(signaturePage.locator('#master-password')).toBeVisible();
  // Check that the login actually works.
  await signaturePage.locator('#master-password').fill(password);
  await signaturePage.getByRole('button', { name: 'Iniciar sesión' }).click();
  await signaturePage.waitForURL('./containers');
  await expect(signaturePage.getByRole('link', { name: 'Abrir APS Conecta Gestión ↗' })).toBeVisible();

  // A signature is preferred over a token: an invalid signature fails even if the token is valid
  const preferredPage = await (await browser.newContext()).newPage();
  await preferredPage.goto(`./api/auth/getlogin?signature=invalid&token=${AIO_TOKEN}`);
  await expect(preferredPage.locator('body')).toContainText('El inicio de sesión directo está bloqueado porque APS Conecta Gestión está en ejecución.');
  await expect(preferredPage.locator('#master-password')).toHaveCount(0);
});

// The private key only lives in the environment of the Nextcloud container, so read it via the Docker API.
async function getUnblockLoginPrivateKey() {
  const body = await new Promise((resolve, reject) => {
    request({ socketPath: '/var/run/docker.sock', path: '/containers/nextcloud-aio-nextcloud/json' }, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data));
    }).on('error', reject).end();
  });
  const env = JSON.parse(body).Config.Env;
  return env.find(e => e.startsWith('AIO_UNBLOCK_LOGIN_PRIVATE_KEY=')).split('=')[1];
}

// Same as sodium_crypto_sign(): the Ed25519 signature followed by the signed message, url-safe base64 encoded.
// A libsodium secret key is the 32 byte seed followed by the 32 byte public key.
function signTimestamp(privateKeyBase64) {
  const secretKey = Buffer.from(privateKeyBase64, 'base64url');
  const key = createPrivateKey({
    key: { kty: 'OKP', crv: 'Ed25519', d: secretKey.subarray(0, 32).toString('base64url'), x: secretKey.subarray(32).toString('base64url') },
    format: 'jwk',
  });
  const message = Buffer.from(String(Math.floor(Date.now() / 1000)));
  return Buffer.concat([sign(null, message, key), message]).toString('base64url');
}
