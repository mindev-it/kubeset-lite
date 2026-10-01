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
ssh kubeset-lt@host kubeset-lt delete <project>          # i volumi dei PVC restano
```

`stream.yaml` è un multi-document YAML già renderizzato da chi deploya, con:

- i manifest che podman capisce: Deployment, Pod, DaemonSet, Job,
  PersistentVolumeClaim, ConfigMap, Secret (Job e DaemonSet diventano Pod,
  vedi sotto). Namespace, Service, Ingress e CronJob non devono esserci;
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

`exec` è `<deployment o pod>/<container> <comando>`: il comando gira con
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
  stop della unit e le ricrea dallo YAML salvato. Una Secret montata come
  file invece diventa un volume con il suo nome, riscritto a ogni avvio, che
  resta su disco in chiaro anche a unit ferma. Lo stesso per le ConfigMap
  montate. `delete` cancella questi volumi, non quelli dei PVC.
- Job e DaemonSet diventano Pod (`spec` = `spec.template.spec`, label e
  annotation dell'oggetto e del template). Quadlet chiama `podman kube play
  --service-container=true`, che crea il service container solo per Pod e
  Deployment: con un Job o un DaemonSet podman va in panic e la unit non
  parte (bug di podman, c'è ancora in 5.7). Lo YAML resta quello di k3s.
  Conseguenze:
  - il container si chiama `<nome>-<container>` (un Deployment invece
    `<nome>-pod-<container>`);
  - di un Job valgono solo il template e la sua `restartPolicy`:
    `backoffLimit`, `completions`, `parallelism` e `activeDeadlineSeconds`
    sono ignorati. Un DaemonSet è un solo Pod, il server è uno;
  - un Pod che finisce da solo (`restartPolicy` diversa da `Always`) porta
    la unit a `inactive` se tutti i container escono con 0, a `failed`
    altrimenti. `apply` e `restart` osservano la unit per 15 secondi: se in
    quel tempo un container esce con errore falliscono e mostrano il log;
  - finito il Job, podman rimuove il pod e `podman logs` non lo trova più:
    i log restano nel journal, `journalctl --user CONTAINER_NAME=<container>`;
  - il Job riparte a ogni `apply`, `restart` e riavvio del server: la unit è
    abilitata all'avvio come quella di un Deployment.

Per il resto si usa podman direttamente: `podman logs`, `podman exec`,
`podman volume ls`.

## Nomi globali sul server

Podman non ha namespace: Secret, ConfigMap e PVC hanno un solo spazio di
nomi per tutto l'utente `kubeset-lt`. Una Secret con lo stesso nome di
quella di un altro progetto la sostituisce senza errore; ConfigMap, Secret
montate e PVC diventano volumi con il loro nome, quindi una ConfigMap e un
PVC di due progetti diversi possono finire sullo stesso volume.

Per questo `apply` rifiuta lo stream, prima di toccare qualsiasi cosa, se un
nome di Secret, ConfigMap o PVC è già usato da un altro progetto (la Secret
del registry non conta, non arriva a podman). Conviene prefissare i nomi col
progetto: `psa-backend-secrets`, `psa-backend-data`.

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
