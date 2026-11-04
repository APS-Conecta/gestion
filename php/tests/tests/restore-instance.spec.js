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

  // Reject example.com (requires enabled domain validation)
  await containersPage.locator('#domain').click();
  await containersPage.locator('#domain').fill('example.com');
  await containersPage.getByRole('button', { name: 'Enviar dominio' }).click();
  await expect(containersPage.locator('body')).toContainText('El dominio no apunta a este servidor o el proxy inverso no está bien configurado.', { timeout: 15 * 1000 });

  // Reject invalid backup location
  await containersPage.locator('#borg_restore_host_location').click();
  await containersPage.locator('#borg_restore_host_location').fill('/tmp/test/aio-incorrect-path');
  await containersPage.locator('#borg_restore_password').click();
  await containersPage.locator('#borg_restore_password').fill(borgBackupPassword);
  await containersPage.getByRole('button', { name: 'Enviar la ubicación y la contraseña de cifrado' }).click()
  await containersPage.getByRole('button', { name: 'Probar la ruta y la contraseña de cifrado' }).click();
  await expect(containersPage.getByRole('main')).toContainText('¡Falló la última prueba!', { timeout: 60 * 1000 });

  // Reject invalid backup password
  await containersPage.locator('#borg_restore_host_location').click();
  await containersPage.locator('#borg_restore_host_location').fill(borgBackupLocation);
  await containersPage.locator('#borg_restore_password').click();
  await containersPage.locator('#borg_restore_password').fill('foobar');
  await containersPage.getByRole('button', { name: 'Enviar la ubicación y la contraseña de cifrado' }).click()
  await containersPage.getByRole('button', { name: 'Probar la ruta y la contraseña de cifrado' }).click();
  await expect(containersPage.getByRole('main')).toContainText('¡Falló la última prueba!', { timeout: 60 * 1000 });

  // Accept correct backup location and password
  await containersPage.locator('#borg_restore_host_location').click();
  await containersPage.locator('#borg_restore_host_location').fill(borgBackupLocation);
  await containersPage.locator('#borg_restore_password').click();
  await containersPage.locator('#borg_restore_password').fill(borgBackupPassword);
  await containersPage.getByRole('button', { name: 'Enviar la ubicación y la contraseña de cifrado' }).click()
  await containersPage.getByRole('button', { name: 'Probar la ruta y la contraseña de cifrado' }).click();

  // Check integrity and restore backup
  await containersPage.getByRole('button', { name: 'Comprobar la integridad de la copia de seguridad' }).click();
  await expect(containersPage.getByRole('main')).toContainText('¡La última comprobación fue exitosa!', { timeout: 5 * 60 * 1000 });
  containersPage.once('dialog', dialog => {
    console.log(`Dialog message: ${dialog.message()}`)
    dialog.accept()
  });
  await containersPage.getByRole('button', { name: 'Restaurar la copia de seguridad seleccionada' }).click();
  await expect(containersPage.getByRole('main')).toContainText('El contenedor de copias de seguridad está en ejecución:', { timeout: 1 * 60 * 1000 });

  // Verify a successful backup restore
  await expect(containersPage.getByRole('main')).toContainText('¡La última restauración fue exitosa!', { timeout: 3 * 60 * 1000 });
  await containersPage.getByText('Haga clic aquí para mostrar todas las opciones de copia de seguridad').click();
  await expect(containersPage.getByText('Mostrar su contraseña de cifrado de las copias de seguridad')).toBeVisible();
  await expect(containersPage.getByRole('main')).toContainText('⚠️ Hay actualizaciones de contenedores disponibles. Haga clic en Detener contenedores y luego en Iniciar y actualizar contenedores para actualizarlos. Le recomendamos crear antes una copia de seguridad.');
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