# Breaker Journal

## 2026-10-05 - Enforce brute-force protection in system config

- Class 10 (platform configuration), sub-item 2 (brute-force protection) for ISO week 41.
- Nextcloud brute-force protection must be explicitly declared as configuration-as-code in `provisioning/phases/05-security.sh` (`auth.bruteforce.protection.enabled true boolean`) so the security posture is immutable across deployments and protected against configuration drift.
- Verified with static assertion in `scripts/test.sh` and smoke check in `scripts/smoke.sh`.
