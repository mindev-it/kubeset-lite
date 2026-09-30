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
  rollout, dalla porta pubblicata. Se non risponde entro
  `progressDeadlineSeconds` del Deployment (180 se manca) la unit viene
  fermata: podman non ha il CrashLoopBackOff.
- La `livenessProbe` deve essere `exec`: una httpGet viene rifiutata, perché
  podman la eseguirebbe con curl dentro il container (in Kubernetes la fa il
  kubelet da fuori). Forma comune a k3s e podman, per immagini con wget
  (alpine e busybox lo hanno):

  ```yaml
  livenessProbe:
    exec:
      command: [wget, -q, --spider, -T, "4", "http://127.0.0.1:3000/health"]
    timeoutSeconds: 5
  ```
- I PVC nascono con proprietario `runAsUser`/`fsGroup` del pod che li monta.
- Le Secret si leggono con `kubeset-lt secret`: podman le cancella a ogni
  stop della unit e le ricrea dallo YAML salvato.

Per il resto si usa podman direttamente: `podman logs`, `podman exec`,
`podman volume ls`.

## Rollout: qualche secondo di disservizio

`apply` e `restart` riavviano la unit del progetto: podman ferma il pod
vecchio e poi avvia il nuovo, come la strategia `Recreate` di Kubernetes.
In mezzo Caddy risponde 502. Il buco dura lo spegnimento del container
(fino a `terminationGracePeriodSeconds`) più l'avvio dell'app: di solito
pochi secondi. Uno script di deploy che dopo l'apply esegue le migration e
fa `restart` ne ha due.

Per un progetto a cui serve, ci sono tre strade, nessuna implementata:

- **Caddy che aspetta**: `lb_try_duration 30s` nel `reverse_proxy` fa
  riprovare Caddy per 30 secondi invece di dare 502. Le richieste durante
  il riavvio diventano lente, non fallite.
- **Migration in un `initContainer`**: podman li supporta, girano fino alla
  fine prima del container dell'app. Toglie il secondo riavvio e vale
  uguale su k3s.
- **Zero downtime vero**: due unit su due porte, la nuova si avvia accanto
  alla vecchia, Caddy passa alla nuova quando è pronta, poi la vecchia si
  ferma. Podman da solo non lo fa. Funziona anche con SQLite, purché le due
  copie stiano sullo stesso host e sullo stesso volume locale: i lock sul
  file serializzano le scritture. SQLite non va messo su un filesystem di
  rete.
