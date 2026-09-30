# kubeset-lite

Gli stessi YAML Kubernetes di un progetto, eseguiti su una VM piccola con
podman rootless (`podman kube play` via Quadlet) e Caddy davanti per l'HTTPS.
Niente cluster, niente demoni nostri: bash, `yq`, `podman`, `systemd`, `caddy`.

Il comando si chiama `kubeset-lt` (`kubeset` è il progetto fratello su k3s).

## Installazione

Su Debian o Ubuntu, da root:

```bash
git clone <repo> && cd kubeset-lite
sudo ./install.sh
```

Crea l'utente `kubeset-lt` (home `/var/lib/kubeset-lt`), installa podman e
Caddy, copia le chiavi ssh di chi lancia `sudo` se l'utente non ne ha.
Rilanciabile: aggiorna `/usr/bin/kubeset-lt` e non tocca la configurazione.

In `/etc/kubeset-lt/kubeset-lt.conf`:

- `ACME_EMAIL`: email per Let's Encrypt (facoltativa);
- `TLS=acme` (certificati veri) oppure `TLS=internal` (CA locale, per le
  macchine di prova senza DNS pubblico).

## Uso

```bash
cat stream.yaml | ssh kubeset-lt@host kubeset-lt apply
ssh kubeset-lt@host kubeset-lt restart <project>
ssh kubeset-lt@host kubeset-lt status [project]
ssh kubeset-lt@host kubeset-lt secret <project> <name>   # 2 se non esiste
ssh kubeset-lt@host kubeset-lt delete <project>          # i volumi restano
```

`stream.yaml` è un multi-document YAML già renderizzato da chi deploya, con:

- i manifest che podman capisce: Deployment, Pod, DaemonSet, Job,
  PersistentVolumeClaim, ConfigMap, Secret. Namespace, Service, Ingress e
  CronJob non devono esserci;
- facoltativa, una Secret `kubernetes.io/dockerconfigjson` con le credenziali
  del registry: serve solo al pull e non resta sul server;
- esattamente un documento `kind: Project`:

```yaml
apiVersion: kubeset-lt/v1
kind: Project
metadata:
  name: psa                     # prefisso di unit, timer e file Caddy
spec:
  publish:                      # porta su 127.0.0.1 : porta del container
    - "8081:3000"
  sites:                        # dominio: porta pubblicata
    psa-controller.example.com: 8081
  cron:
    poll-charging-monitors:
      on: "*:*:00"              # OnCalendar di systemd
      exec: psa-backend/api node dist/jobs/poll-charging-monitors.js
      timeout: 240s
```

`exec` è `<deployment>/<container> <comando>`: il comando gira con
`podman exec` dentro il container già attivo.

## Cosa cambia rispetto a Kubernetes

- `imagePullPolicy` diventa `Never`: l'immagine scaricata all'apply resta e
  basta anche dopo un riavvio, senza credenziali.
- La `readinessProbe` httpGet la usa solo `apply`/`restart` per attendere il
  rollout, dalla porta pubblicata. Se il rollout fallisce entro 180 secondi
  la unit viene fermata: podman non ha il CrashLoopBackOff.
- Le `livenessProbe` httpGet vengono tolte: podman le eseguirebbe con curl
  dentro il container.
- I PVC nascono con proprietario `runAsUser`/`fsGroup` del pod che li monta.
- Le Secret si leggono con `kubeset-lt secret`: podman le cancella a ogni
  stop della unit e le ricrea dallo YAML salvato.

Per il resto si usa podman direttamente: `podman logs`, `podman exec`,
`podman volume ls`.
