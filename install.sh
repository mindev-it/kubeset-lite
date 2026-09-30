#!/bin/bash
# kubeset-lite: installazione su Debian/Ubuntu.
# Da root, idempotente: si rilancia per aggiornare il comando o dopo aver
# cambiato /etc/kubeset-lt/kubeset-lt.conf.
#
#   sudo ./install.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

USER_NAME=kubeset-lt
HOME_DIR=/var/lib/kubeset-lt
CONF_DIR=/etc/kubeset-lt
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

log() { echo -e "\033[0;34m[kubeset-lt]\033[0m $*"; }
die() { echo -e "\033[0;31m[kubeset-lt]\033[0m $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Serve root: sudo ./install.sh"
[ -f /etc/debian_version ] || die "Supportati solo Debian e Ubuntu"

# Pacchetti. Caddy dal repo ufficiale: Debian e Ubuntu hanno la 2.6.2.
if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
    log "Aggiungo il repo di Caddy"
    apt-get update
    apt-get install -y curl gnupg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
fi
log "Installo i pacchetti"
apt-get update
apt-get install -y podman uidmap passt dbus-user-session sudo yq jq curl caddy

# Utente rootless che esegue i container e riceve i deploy via ssh.
if ! id "$USER_NAME" &>/dev/null; then
    log "Creo l'utente $USER_NAME"
    useradd -m -d "$HOME_DIR" -s /bin/bash "$USER_NAME"
fi
if ! grep -q "^$USER_NAME:" /etc/subuid; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER_NAME"
fi
loginctl enable-linger "$USER_NAME"
# Caddy (utente caddy) deve attraversare la home per leggere caddy/.
chmod 711 "$HOME_DIR"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$HOME_DIR/caddy"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "$HOME_DIR/.ssh"

KEYS="$HOME_DIR/.ssh/authorized_keys"
if [ ! -s "$KEYS" ]; then
    FROM=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.ssh/authorized_keys
    if [ -s "$FROM" ]; then
        log "Copio le chiavi ssh di ${SUDO_USER:-root} in $KEYS"
        install -o "$USER_NAME" -g "$USER_NAME" -m 600 "$FROM" "$KEYS"
    else
        log "ATTENZIONE: $KEYS è vuoto, nessuno potrà fare ssh $USER_NAME@$(hostname -f)"
    fi
fi

# Configurazione: creata solo se manca, poi è dell'amministratore.
install -d -m 755 "$CONF_DIR"
if [ ! -f "$CONF_DIR/kubeset-lt.conf" ]; then
    log "Creo $CONF_DIR/kubeset-lt.conf"
    cat > "$CONF_DIR/kubeset-lt.conf" <<'EOF'
# Letto da kubeset-lt a ogni apply.

# Email per Let's Encrypt (facoltativa).
ACME_EMAIL=

# acme: certificati veri, il DNS deve puntare qui.
# internal: CA locale di Caddy, per macchine di prova senza DNS pubblico.
TLS=acme
EOF
fi

# Caddyfile: solo l'import dei siti generati da kubeset-lt. Quello di
# default del pacchetto viene messo da parte una volta.
CADDYFILE=/etc/caddy/Caddyfile
if ! grep -qF "import $HOME_DIR/caddy/*.caddy" "$CADDYFILE" 2>/dev/null; then
    log "Scrivo $CADDYFILE (l'originale resta in $CADDYFILE.dist)"
    [ -f "$CADDYFILE" ] && [ ! -f "$CADDYFILE.dist" ] && mv "$CADDYFILE" "$CADDYFILE.dist"
    cat > "$CADDYFILE" <<EOF
# Siti generati da kubeset-lt, uno per progetto.
import $HOME_DIR/caddy/*.caddy
EOF
fi
systemctl enable caddy
systemctl reload-or-restart caddy

# L'utente può solo ricaricare Caddy.
SUDOERS=$(mktemp)
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl reload caddy" > "$SUDOERS"
visudo -cqf "$SUDOERS" || die "sudoers non valido"
install -m 440 "$SUDOERS" "/etc/sudoers.d/$USER_NAME"
rm -f "$SUDOERS"

# Firewall: le immagini Oracle chiudono tutto con un REJECT in INPUT.
if iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
    for port in 80 443; do
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            log "Apro la porta $port"
            iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
        fi
    done
    if [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4
    else
        log "ATTENZIONE: /etc/iptables non esiste, le porte si richiudono al riavvio"
    fi
fi

# Il comando si sovrascrive sempre.
install -m 755 "$SRC_DIR/bin/kubeset-lt" /usr/bin/kubeset-lt

log "Fatto. Prova: ssh $USER_NAME@$(hostname -f) kubeset-lt status"
