// Shared login flow for the wizard's Playwright scenarios (the fork's es-CL suite, patch 090).
//
// ./setup renders the one-time passphrase page while the instance is not installed; we scrape
// the passphrase, open the login in the popup (the setup link keeps target="_blank"), and log
// in there — the containers page is the popup, the setup page stays behind it.

import { expect } from '@playwright/test';

export async function logInToContainersPage(setupPage) {
  // Extract initial password
  await setupPage.goto('./setup');
  const password = await setupPage.locator('#initial-password').innerText()
  const containersPagePromise = setupPage.waitForEvent('popup');
  await setupPage.getByRole('link', { name: 'Abrir el inicio de sesión de APS Conecta Gestión AIO ↗' }).click();
  const containersPage = await containersPagePromise;

  // Typing must not reveal the passphrase; only the reveal button toggles it
  const passwordField = containersPage.locator('#master-password');
  await passwordField.click();
  await passwordField.fill(password);
  await expect(passwordField).toHaveAttribute('type', 'password');
  await containersPage.getByRole('button', { name: 'Mostrar frase de contraseña' }).click();
  await expect(passwordField).toHaveAttribute('type', 'text');
  await containersPage.getByRole('button', { name: 'Ocultar frase de contraseña' }).click();
  await expect(passwordField).toHaveAttribute('type', 'password');

  // Log in and wait for redirect
  await containersPage.getByRole('button', { name: 'Iniciar sesión' }).click();
  await containersPage.waitForURL('./containers');
  return containersPage;
}
