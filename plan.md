# kubeset-lite: piano di sviluppo

Riferimenti: `idea.md` (il perché), `~/Work/Sys/web-server-orchestrator` (lo
stile: `install.sh` idempotente, comandi in `/usr/bin`, niente demoni nostri),
`~/Work/psa-car/backend` (primo progetto da migrare, primo server: host4).

Nome: il progetto è kubeset-lite, ma comando, utente, percorsi e prefissi
sono `kubeset-lt`. `kubeset` è riservato al progetto fratello su k3s (oggi
kwo).

Principio: semplicità assoluta. Bash, `yq`, `podman`, `systemd`, `caddy`.
kubeset-lt non reimplementa Kubernetes: passa a `podman kube play` solo i kind
che podman capisce, e per il resto (HTTPS, cron) legge un documento YAML suo.

## Tre famiglie di YAML nel repo del progetto

- **Comuni a k3s e podman**: Deployment, PVC, Secret, ConfigMap, Job. Sono i
  file che esistono già in `deploy/k8s/` e non si toccano.
- **Solo k3s**: Namespace, Service, Ingress, CronJob. Restano dove sono, li
  usa solo `deploy.sh`. kubeset-lt non li riceve.
- **Solo kubeset-lt**: `deploy/kubeset-lt.yaml`, un documento `kind: Project` che
  kubeset-lt legge e scarta prima di chiamare podman.

```yaml
apiVersion: kubeset-lt/v1
kind: Project
metadata:
  name: psa                     # prefisso di tutto ciò che kubeset-lt genera
spec:
  publish:                      # → PublishPort=127.0.0.1:<host>:<container>
    - "8081:3000"
  sites:                        # → blocco Caddy con reverse_proxy
    ${HOST}: 8081
  cron:                         # → timer systemd utente
    poll-charging-monitors:
      on: "*:*:00"              # OnCalendar di systemd, così com'è
      exec: psa-backend/api node dist/jobs/poll-charging-monitors.js
      timeout: 240s
    cleanup-stale-users:
      on: "*-*-* 03:00:00 UTC"
      exec: psa-backend/api node dist/jobs/cleanup-stale-users.js
```

Scelte:

- `on` usa la sintassi di systemd, niente conversione dal formato cron:
  zero codice, e `systemd-analyze calendar` la valida prima di scriverla.
- `exec` gira dentro il container già attivo (`podman exec
  psa-backend-pod-api ...`): stessa immagine, stesse variabili, stessa Secret,
  stesso volume, niente da duplicare. Il processo conta nel limite di memoria
  del container. Se un giorno serve un job pesante e isolato, si aggiunge
  `run:` che punta a un `kind: Job` (podman lo supporta già).
- `concurrencyPolicy: Forbid` è gratis: systemd non rilancia una unit attiva.
  `timeout` → `RuntimeMaxSec`.

## Interfaccia

```bash
cat stream.yaml | ssh kubeset-lt@host kubeset-lt apply
ssh kubeset-lt@host kubeset-lt restart <project>     # restart + attesa readiness
ssh kubeset-lt@host kubeset-lt status [project]
ssh kubeset-lt@host kubeset-lt secret <project> <name>  # la Secret com'è nello YAML applicato
ssh kubeset-lt@host kubeset-lt delete <project>      # volumi esclusi
```

`stream.yaml` è un multi-document YAML già renderizzato dal deployer
(envsubst lato client, come oggi) con esattamente un `kind: Project`.

Per il resto si usa podman direttamente, niente wrapper:
`podman logs`, `podman exec`. Le Secret invece si leggono con `kubeset-lt
secret`, perché podman le cancella a ogni stop della unit (vedi Verificato):
la copia che conta è quella nello YAML su disco.

Utente ssh: **`kubeset-lt`** (rootless, home `/var/lib/kubeset-lt`). Chi deploya
deve già poter fare `ssh kubeset-lt@host` col proprio agent.

## Credenziali del registry

Solo temporanee. Il deployer le mette nello stream come Secret di tipo
`kubernetes.io/dockerconfigjson` (una riga con `kubectl create secret
docker-registry --dry-run=client -o yaml`). kubeset-lt:

1. la toglie dallo stream e la scrive in `$XDG_RUNTIME_DIR` (tmpfs) come
   `.docker-tmp/config.json`, con trap che la cancella anche se lo script
   fallisce;
2. esporta `DOCKER_CONFIG` e fa `podman pull` di tutte le immagini;
3. riscrive `imagePullPolicy: Never`: da lì in poi podman usa solo l'immagine
   locale, che resta anche dopo i riavvii.

Podman non supporta `imagePullSecrets` e Quadlet `.kube` non ha `AuthFile=`,
quindi questa è anche l'unica strada che non lascia credenziali sul server.

**Prune sul server**: dopo ogni apply riuscito, `podman image prune -f`
(versioni precedenti di uno stesso tag, rimaste senza nome dopo il pull) e
`podman rmi` delle immagini con tag che nessun progetto cita più. Niente
regole sull'età: resta solo l'immagine in uso. La pulizia del registry
invece è compito dello script di deploy del progetto (vedi agente psa).

## Cosa fa `kubeset-lt apply`

1. Legge stdin in una dir sotto `$XDG_RUNTIME_DIR`, trap di pulizia.
2. Separa: `kind: Project`, Secret dockerconfigjson, resto per podman. Un
   kind che podman non supporta → errore esplicito (Namespace, Service,
   Ingress e CronJob non devono arrivare). Una `livenessProbe` httpGet →
   errore: podman la esegue con curl dentro il container (senza curl
   nell'immagine il container riparte all'infinito), quindi i progetti usano
   `exec` con wget, che vale uguale su k3s. Ritocco per podman: aggiunge ai
   PVC le annotation `volume.podman.io/uid|gid` prese dal `securityContext`
   del pod che li monta (senza, il volume nasce di root).
3. Pull con `DOCKER_CONFIG`. Se fallisce, esce senza toccare niente.
4. Scrive `~/.config/containers/systemd/<project>/<project>.yaml` (600) e
   `<project>.kube` con i `PublishPort`. Una sola unit per progetto.
5. `daemon-reload`, restart di `<project>.service`.
6. Rollout: se un container ha `readinessProbe.httpGet`, curl sulla porta
   pubblicata fino a OK o timeout (`progressDeadlineSeconds` del Deployment,
   180s se manca). Altrimenti basta la unit attiva.
7. Solo dopo il rollout, i timer: scrive
   `~/.config/systemd/user/kubeset-lt-<project>_<cron>.{service,timer}`, cancella
   i `kubeset-lt-<project>_*` che non sono più nel documento, `enable --now`.
   Il prefisso col nome progetto è ciò che rende possibile il delete di un
   cron tolto; il `_` non è ammesso nei nomi di progetto, quindi `psa` non
   tocca i cron di `psa-x`.
8. Caddy: `/var/lib/kubeset-lt/caddy/<project>.caddy`; se cambiato,
   `sudo systemctl reload caddy`.
9. Prune delle immagini.

## Layout sul server

```
/usr/bin/kubeset-lt                           comando unico
/etc/kubeset-lt/kubeset-lt.conf               ACME_EMAIL, TLS (acme | internal)
/etc/caddy/Caddyfile                          globali + import /var/lib/kubeset-lt/caddy/*.caddy
/etc/sudoers.d/kubeset-lt                     kubeset-lt → solo "systemctl reload caddy"
/var/lib/kubeset-lt/                          home dell'utente kubeset-lt
  .config/containers/systemd/<project>/       yaml + .kube
  .config/systemd/user/kubeset-lt-<project>_* timer dei cron
  caddy/<project>.caddy
```

## `install.sh` (da root, idempotente, rilanciabile)

- apt: `podman`, `uidmap`, `passt`, `yq`, `curl`, `jq`; Caddy dal repo
  ufficiale Cloudsmith (Ubuntu e Debian hanno la 2.6.2).
- utente `kubeset-lt` con home `/var/lib/kubeset-lt`, `loginctl enable-linger`.
- `authorized_keys` di kubeset-lt: se vuoto, copia quello di `$SUDO_USER`.
- Caddyfile e `kubeset-lt.conf` creati solo se mancano. `/usr/bin/kubeset-lt`
  sovrascritto sempre.
- sudoers validato con `visudo -c`.
- firewall: se c'è un REJECT in INPUT (immagini Oracle), apre 80/443 in
  `/etc/iptables/rules.v4`. Su host4 oggi la policy è già ACCEPT.

## Verificato sulla VM di sviluppo (27/09)

Podman 5.4.2, utente `kubeset-lt` rootless:

- cgroup delegati all'utente: `cpu memory pids` → i limiti del manifest
  valgono.
- Quadlet legge le sottocartelle (`systemd/prova/prova.kube` → `prova.service`).
- `PublishPort=127.0.0.1:8081:3000` nel `.kube` funziona con un Deployment
  che dichiara solo `containerPort: 3000`.
- `envFrom.secretRef` su una Secret dello stesso YAML funziona. Allo stop
  della unit podman cancella la Secret e la ricrea allo start dallo YAML; il
  volume invece resta.
- Volume: sull'utente appena creato (30/09) il volume nuovo è nato di root
  (0:0), come nella primissima prova del 27/09, e il container con
  `runAsUser: 1000` non ci scriveva. Con le annotation `volume.podman.io/uid`
  e `gid` messe da kubeset-lt nasce 1000:1000. Valgono solo alla creazione:
  un volume già esistente con il proprietario sbagliato va sistemato a mano
  (`podman unshare chown`).
- `livenessProbe` httpGet → healthcheck `curl -f http://localhost:<porta>`
  dentro il container, con riavvio a ogni fallimento: con busybox (niente
  curl) 9 riavvii in 3 minuti. La `readinessProbe` podman la ignora; la usa
  solo il rollout di kubeset-lt, da fuori.
- Attenzione: `restartPolicy: Always` di podman rilancia un container che
  crasha senza pausa (niente CrashLoopBackOff). Su 1/8 di OCPU un crash loop
  pesa: se il rollout fallisce, kubeset-lt ferma la unit.

## Ambienti

- **Sviluppo**: `root@k3s-local.chdev.eu` (Debian 13, podman 5.4, rete
  privata). Repo in `/srv/Work/mindev/kubeset-lite` via virtiofs. Caddy con
  `TLS=internal`; i domini veri non puntano alla VM, quindi le prove HTTPS
  passano da `curl --resolve <host>:443:192.168.122.239`.
- **Produzione**: `ubuntu@host4.net.mindev.it` (Ubuntu 26.04, podman 5.7).

## Due agenti

**Agente main (questo repo)**: `install.sh`, `bin/kubeset-lt`, README, prove
sulla VM con manifest minimi.

**Agente psa (`~/Work/psa-car/backend`)**:

- Branch: oggi c'è solo `master` (GitHub `marcochiodo/psa-car-backend`). Si
  passa a `dev` (lavoro) + `main` (produzione) come hail: rinomina di
  `master` in `main` anche su GitHub (branch di default) e creazione di
  `dev`. Tocca il remote: si fa solo con conferma.
- `deploy.sh` e `deploy/k8s/` intatti (a parte `GIT_BRANCH` dopo la
  rinomina, se si vuole che l'originale funzioni ancora). Nuovi:
  `deploy-kubeset-lite.sh` e `deploy/kubeset-lt.yaml`.
- Passi git come `deploy.sh` di hail: working tree pulito, offerta di
  allineare `main` a `dev`, build solo da `origin/main` via `git archive`.
- Bitwarden come da skill `backend-development` (punto 5): una sola
  `bw list items --folderid` sulla cartella dei segreti, poi una riga jq per
  item, niente wrapper. Cartella: `5c5355fa-5e55-4027-ad9d-b3a001038038`
  (cartella `secrets`, la stessa di hail, strapi e visiva). Item generico
  `scw-deployer-registry-user`: solo `login.username` e `login.password`.
  Essendo generico, il percorso dell'immagine
  (`rg.it-mil.scw.eu/psa-car/psa-backend`) sta in chiaro in testa allo
  script, come oggi `IMAGE`.
- Con quelle credenziali si scrive un solo `config.json` in `/dev/shm`
  (trap). Serve due volte: `docker --config <dir> push` dal computer, così
  il login Scaleway non finisce in `~/.docker/config.json`, e la Secret
  dockerconfigjson dello stream per il pull sul server.
- Immagine: `rg.it-mil.scw.eu/psa-car/psa-backend:<sha di origin/main>`.
  Un tag per commit invece di `:prod`, perché servono tag distinti per
  tenere le ultime tre. Il deployment non cambia (usa già `${IMAGE}`).
- Dopo il push riuscito: API Scaleway (`X-Auth-Token` = la stessa secret
  key del registry) → lista dei tag dell'immagine per data, cancellazione di
  tutti tranne i 3 più recenti. Solo curl e jq.
- Secret `psa-backend-secrets`: riusa se esiste (`kubeset-lt secret psa
  psa-backend-secrets` via ssh), altrimenti genera con openssl come oggi.
- Stream: `pvc.yaml`, `deployment.yaml` (envsubst), Secret dell'app, Secret
  dockerconfigjson, `kubeset-lt.yaml` (envsubst) → `kubeset-lt apply`.
- Migration come oggi: `podman exec psa-backend-pod-api node
  dist/db/migrate.js` via ssh, poi `kubeset-lt restart psa`.
- Target in variabile (`TARGET=kubeset-lt@host4.net.mindev.it`, override per la
  VM).
- Ultima fase, con conferma: copia di `psa.db` dal PVC su host2 al volume su
  host4 e cambio DNS di `psa-controller.chdev.eu`.

Se `deploy/k8s/*.yaml` non passa da podman, è un bug di kubeset-lt: si segnala
all'agente main, non si modifica il manifest.

## Fasi

1. `install.sh` sulla VM.
2. `kubeset-lt apply` / `restart` / `status` / `delete` con un progetto di prova:
   pull con credenziali temporanee, porta, Caddy, readiness, prune.
   Sopravvive a `reboot` senza credenziali.
3. Cron → timer, compresa la rimozione di un cron tolto dal documento.
4. psa sulla VM con `deploy-kubeset-lite.sh`.
5. `install.sh` su host4, deploy di psa.
6. Migrazione dati e DNS di psa.

## Stato al 30/09

- Fasi 1-3 fatte e provate sulla VM con un progetto di prova (busybox da un
  registry locale con password su `localhost:5000`):
  - `install.sh`: prima installazione e rilancio senza errori;
  - `apply`: pull con credenziali temporanee, nessun file di credenziali sul
    server;
  - HTTPS via Caddy con `TLS=internal`;
  - aggiornamento di immagine e Secret, con prune della versione precedente;
  - `secret`: codice di uscita 0 se c'è, 2 se non c'è;
  - pull fallito: esce senza toccare niente e il sito resta su;
  - readinessProbe che non risponde: la unit viene fermata dopo 180 secondi;
  - cron aggiunto e tolto;
  - `timeout` del cron: uccide anche il processo dentro il container;
  - `restart` e `delete` funzionano;
  - dopo il `reboot` il progetto riparte senza credenziali.
- `livenessProbe` httpGet rifiutata, timeout del rollout da
  `progressDeadlineSeconds`: provati sulla VM.
- Fase 4 fatta: psa deployato sulla VM con `deploy-kubeset-lite.sh`:
  - push su `rg.it-mil.scw.eu` (dominio confermato da Scaleway), l'API
    Registry risponde su `it-mil`;
  - container healthy con la sonda `wget`, limiti 256Mi e 500m applicati;
  - volume 1000:1000, migration eseguite;
  - cron `poll-charging-monitors` eseguito con successo;
  - HTTPS via Caddy risponde 200.
- psa-car: `master` rinominato `main` su GitHub, creato `dev`. `deploy.sh`
  ha ancora `GIT_BRANCH="master"`: non funziona finché non si cambia.
- VM di sviluppo:
  - `/etc/kubeset-lt/kubeset-lt.conf` ha `TLS=internal`;
  - il registry di prova gira come root (container `testreg`, registries.conf
    in `/etc/containers/registries.conf.d/testreg.conf`);
  - attivo solo `psa`, con una Secret generata sulla VM (non quella di host2).
- Da provare: un secondo deploy di psa, per vedere la Secret riusata e la
  pulizia del registry con più di tre tag.
- host4: non toccato.
