# Changelog

Tutte le modifiche rilevanti a questo progetto sono documentate qui.
Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/)
e il versionamento [SemVer](https://semver.org/lang/it/).

## [1.0.2] - 2026-06-30

Correzioni emerse dal deploy reale in produzione e miglioramenti di idempotenza.

### Corretto
- **common**: rimossa la ricorsione infinita su `users` (era un self-reference
  `users: "{{ users | default([]) }}"` nell'include del ruolo). Il default `users: []`
  vive ora in `group_vars` (vars.yml.example). Verificato a runtime.
- **ansible.cfg**: il callback `yaml` (rimosso da `community.general` 12+) è sostituito
  da `ansible.builtin.default` con `callback_result_format = yaml`. Output invariato.
- **phpmyadmin**: la `location` è ora servita dal vhost (ruolo `webserver`), non più
  iniettata con `blockinfile` — niente "togli e rimetti" a ogni run.
- **phpmyadmin**: `blowfish_secret` persistente (`/var/lib/phpmyadmin/blowfish.secret`),
  non più rigenerato a ogni deploy (niente logout delle sessioni).

### Aggiunto
- **teardown.yml** + `make teardown CONFIRM=PULISCI`: ripulisce il CT per ripartire da
  zero (servizi, pacchetti, dati, cron, backup, UFW, certificati locali) senza distruggere
  il container e senza revocare i certificati su Let's Encrypt.
- **inventory/hosts.yml.example**: l'inventario reale (`hosts.yml`) è ora escluso dal repo,
  come `vars.yml` e `vault.yml`. CI e `make init` lo materializzano dall'esempio.

## [1.0.0] - 2026-06-30

Prima release stabile. Deploy testato in produzione su un CT Debian 13 (Trixie)
in Proxmox, con HTTPS valido.

### Aggiunto
- Playbook `site.yml`: stack completo Nginx + PHP-FPM 8.4 + MariaDB + Redis + WP-CLI.
- Bootstrap automatico di `python3` per immagini Debian minimal.
- Ruolo `common` con integrazione del ruolo base `mikysal78.ninux_common`.
- Ruolo `hardening`: UFW, fail2ban, SSH drop-in, sysctl (`/etc/sysctl.d/`),
  unattended-upgrades, utente sudo non-root.
- Ruolo `database`: MariaDB con tuning InnoDB in base alla RAM del CT.
- Ruolo `php`: PHP-FPM 8.4, estensioni, OPcache e pool auto-dimensionati.
- Ruolo `redis`: object cache con limiti di memoria.
- Ruolo `webserver`: Nginx, vhost, micro-cache FastCGI, security headers.
- Ruolo `wordpress`: install via WP-CLI, salts, plugin redis-cache, permessi sicuri.
- Ruolo `phpmyadmin`: download, path non standard, Basic Auth.
- Ruolo `backup`: directory, script con retention, cron giornaliero.
- Playbook standalone `letsencrypt.yml` con staging, force e hook di reload al rinnovo.
- Riepilogo accessi con credenziali + file `credentials-<dominio>.txt` (0600).
- `Makefile` con scorciatoie (deploy, https, backup, lint, vault).
- CI GitHub Actions: `yamllint` + `ansible-lint` (profilo `production`).
- README dettagliato e file di esempio `vars.yml.example` / `vault.yml.example`.

### Note
- `vars.yml` e `vault.yml` sono esclusi dal repo: si creano dai rispettivi `.example`.
- Dipendenze Galaxy installate in `galaxy_roles/` e `collections/` (non versionate).

[1.0.2]: https://github.com/mikysal78/wordpress-trixie-ansible/releases/tag/v1.0.2
[1.0.0]: https://github.com/mikysal78/wordpress-trixie-ansible/releases/tag/v1.0.0
