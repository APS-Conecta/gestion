import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { logInToContainersPage } from './helpers.js';

test('Restore instance', async ({ page: setupPage }) => {
  test.setTimeout(10 * 60 * 1000)

  // Load passwords from previous test
  const {
    initialNextcloudPassword,
    borgBackupLocation,
    borgBackupPassword,
  } = JSON.parse(readFileSync('test_data.json'))

  const containersPage = await logInToContainersPage(setupPage);

  // Reject an IP address while domain validation is on (patch 233 accepts one only when it is
  // skipped; PHP-borne English: ConfigurationManager.php — stays, zero-PHP)
  await containersPage.locator('#domain').click();
  await containersPage.locator('#domain').fill('1.1.1.1');
  await containersPage.getByRole('button', { name: 'Enviar dominio' }).click();
  await expect(containersPage.locator('body')).toContainText('Please enter a domain and not an IP-address!');

  // Reject example.com (requires enabled domain validation)
  await containersPage.locator('#domain').click();
  await containersPage.locator('#domain').fill('example.com');
  await containersPage.getByRole('button', { name: 'Enviar dominio' }).click();
  await expect(containersPage.locator('body')).toContainText('Domain does not point to this server or the reverse proxy is not configured correctly.', { timeout: 15 * 1000 });

  // Reject invalid backup location
  await containersPage.locator('#borg_restore_host_location').click();
  await containersPage.locator('#borg_restore_host_location').fill('/tmp/test/aio-incorrect-path');
  await containersPage.locator('#borg_restore_password').click();
  await containersPage.locator('#borg_restore_password').fill(borgBackupPassword);
  await containersPage.getByRole('button', { name: 'Enviar ubicación y contraseña de cifrado' }).click()
  await containersPage.getByRole('button', { name: 'Probar ruta y contraseña de cifrado' }).click();
  await expect(containersPage.getByRole('main')).toContainText('¡El último test falló!', { timeout: 60 * 1000 });

  // Reject invalid backup password
  await containersPage.locator('#borg_restore_host_location').click();
  await containersPage.locator('#borg_restore_host_location').fill(borgBackupLocation);
  await containersPage.locator('#borg_restore_password').click();
  await containersPage.locator('#borg_restore_password').fill('foobar');
  await containersPage.getByRole('button', { name: 'Enviar ubicación y contraseña de cifrado' }).click()
  await containersPage.getByRole('button', { name: 'Probar ruta y contraseña de cifrado' }).click();
  await expect(containersPage.getByRole('main')).toContainText('¡El último test falló!', { timeout: 60 * 1000 });

  // Accept correct backup location and password
  await containersPage.locator('#borg_restore_host_location').click();
  await containersPage.locator('#borg_restore_host_location').fill(borgBackupLocation);
  await containersPage.locator('#borg_restore_password').click();
  await containersPage.locator('#borg_restore_password').fill(borgBackupPassword);
  await containersPage.getByRole('button', { name: 'Enviar ubicación y contraseña de cifrado' }).click()
  await containersPage.getByRole('button', { name: 'Probar ruta y contraseña de cifrado' }).click();

  // Check integrity and restore backup
  await containersPage.getByRole('button', { name: 'Comprobar la integridad de la copia de seguridad' }).click();
  await expect(containersPage.getByRole('main')).toContainText('¡El último check fue exitoso!', { timeout: 5 * 60 * 1000 });
  containersPage.once('dialog', dialog => {
    console.log(`Dialog message: ${dialog.message()}`)
    dialog.accept()
  });
  await containersPage.getByRole('button', { name: 'Restaurar la copia de seguridad seleccionada' }).click();
  await expect(containersPage.getByRole('main')).toContainText('El contenedor de copias de seguridad está actualmente en ejecución:', { timeout: 1 * 60 * 1000 });

  // Verify a successful backup restore
  await expect(containersPage.getByRole('main')).toContainText('¡El último restore fue exitoso!', { timeout: 3 * 60 * 1000 });
  await containersPage.getByText('Haga clic aquí para mostrar todas las opciones de copia de seguridad').click();
  await expect(containersPage.getByText('Mostrar su contraseña de cifrado para las copias de seguridad')).toBeVisible();
  await expect(containersPage.getByRole('main')).toContainText('⚠️ Hay actualizaciones disponibles para los contenedores.');
  containersPage.once('dialog', dialog => {
    console.log(`Dialog message: ${dialog.message()}`)
    dialog.accept()
  });
  await containersPage.getByRole('button', { name: 'Iniciar y actualizar contenedores' }).click();
  await expect(containersPage.getByRole('link', { name: 'Abrir APS Conecta Gestión ↗' })).toBeVisible({ timeout: 8 * 60 * 1000 });
  await expect(containersPage.getByRole('main')).toContainText(initialNextcloudPassword);

  // Verify that containers are all stopped
  await containersPage.getByRole('button', { name: 'Detener contenedores' }).click();
  await expect(containersPage.getByRole('button', { name: 'Iniciar contenedores' })).toBeVisible({ timeout: 60 * 1000 });
});
