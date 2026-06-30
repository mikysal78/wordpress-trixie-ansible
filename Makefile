# Makefile - WordPress su Debian Trixie (Proxmox LXC)
# Scorciatoie per le operazioni piu' comuni. Lancia `make` o `make help`.

ANSIBLE_PLAYBOOK ?= ansible-playbook
SITE             ?= site.yml
LE               ?= letsencrypt.yml
# Autenticazione vault: default chiede la password interattivamente.
# Per usare un file:  make deploy VAULT="--vault-password-file .vault_pass"
VAULT            ?= --ask-vault-pass
# Argomenti extra:    make deploy EXTRA="-e ct_memory_mb=4096"
EXTRA            ?=

.DEFAULT_GOAL := help

help: ## Mostra questo aiuto
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

init: ## Crea vars.yml e vault.yml dagli esempi (se mancanti)
	@[ -f group_vars/all/vars.yml ] || cp group_vars/all/vars.yml.example group_vars/all/vars.yml
	@[ -f group_vars/all/vault.yml ] || cp group_vars/all/vault.yml.example group_vars/all/vault.yml
	@[ -f inventory/hosts.yml ] || cp inventory/hosts.yml.example inventory/hosts.yml
	@echo "File pronti. Modifica vars.yml e vault.yml, poi cifra: make vault-encrypt"

deps: ## Installa ruoli e collections Galaxy
	ansible-galaxy install -r requirements.yml

ping: ## Verifica la connessione SSH al CT
	ansible -m ping wordpress

syntax: ## Controllo sintassi del playbook
	$(ANSIBLE_PLAYBOOK) $(SITE) --syntax-check

lint: ## yamllint + ansible-lint
	yamllint .
	ansible-lint

check: ## Prova a vuoto (dry-run con diff)
	$(ANSIBLE_PLAYBOOK) $(SITE) $(VAULT) --check --diff $(EXTRA)

deploy: ## Deploy completo dello stack
	$(ANSIBLE_PLAYBOOK) $(SITE) $(VAULT) $(EXTRA)

https-staging: ## Certificato Let's Encrypt di TEST (staging, no rate-limit)
	$(ANSIBLE_PLAYBOOK) $(LE) $(VAULT) -e letsencrypt_staging=true $(EXTRA)

https: ## Certificato Let's Encrypt reale
	$(ANSIBLE_PLAYBOOK) $(LE) $(VAULT) $(EXTRA)

https-force: ## Forza la ri-emissione del certificato (es. staging -> prod)
	$(ANSIBLE_PLAYBOOK) $(LE) $(VAULT) -e letsencrypt_force=true $(EXTRA)

backup: ## Lancia subito un backup sul CT
	ansible wordpress -b -a "/usr/local/sbin/wp-backup.sh"

teardown: ## Pulisce il CT (DISTRUTTIVO). Uso: make teardown CONFIRM=PULISCI
	$(ANSIBLE_PLAYBOOK) teardown.yml $(VAULT) -e confirm=$(CONFIRM) $(EXTRA)

vault-edit: ## Modifica il vault cifrato
	ansible-vault edit group_vars/all/vault.yml

vault-encrypt: ## Cifra il vault
	ansible-vault encrypt group_vars/all/vault.yml

vault-view: ## Mostra il contenuto del vault
	ansible-vault view group_vars/all/vault.yml

.PHONY: help init deps ping syntax lint check deploy https https-staging https-force backup teardown vault-edit vault-encrypt vault-view
