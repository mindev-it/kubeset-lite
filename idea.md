# kube-mini

Equivalente di KWO (k3s-web-orchestrator) per macchine troppo piccole per
Kubernetes: stessi manifest YAML, ma eseguiti da Podman invece che da un
cluster, con Caddy davanti per HTTPS.

## Perché

Obiettivo: usare le VM Oracle Always Free VM.Standard.E2.1.Micro (x86, 1 GB
RAM, 1/8 di OCPU) per ospitare 1-3 app PHP + SQLite ciascuna, mantenendo lo
stile "k8s based" delle app (Deployment, ConfigMap, Secret, PVC).

k3s su una micro non regge, e il problema non è la RAM ma la CPU:

- k3s a vuoto consuma ~80 millicore in continuo (misurato su VM con CPU vera:
  77 senza GOMEMLIMIT, 86 con GOMEMLIMIT=300MiB).
- La micro garantisce 1/8 di OCPU; dopo i picchi l'hypervisor si riprende la
  CPU. Su host4 (Ubuntu 26.04, eu-milan-1) con KWO installato e nessuna app:
  steal 93,9%, load 14-16, k3s in crash loop (lease del nodo non rinnovato in
  tempo → riavvio → swap → peggio).
- Dopo la disinstallazione di k3s: CPU idle 99,8%, steal 0, 602 MB disponibili.

Le A1 Ampere (1 OCPU / 6 GB) restano per k3s + KWO. Le micro usano kube-mini.

## Architettura

```
Internet ──443──> Caddy (systemd, host)
                    │  un blocco per dominio, TLS Let's Encrypt automatico
                    ├──> 127.0.0.1:8081 ──> pod app1 (podman kube play)
                    ├──> 127.0.0.1:8082 ──> pod app2
                    └──> 127.0.0.1:8083 ──> pod app3
```

- **Container sì, demone no.** Le app girano come container OCI (stessa
  immagine buildata in CI e pushata sul registry di sempre), ma le esegue
  Podman, che non ha un demone sempre acceso.
- **`podman kube play`** legge direttamente lo YAML Kubernetes.
- **Quadlet** (`.kube`) trasforma ogni app in un servizio systemd: systemd fa
  la parte che in k8s fa il control plane (avvio al boot, stop, restart).
- **Caddy** fa da reverse proxy + HTTPS al posto di Traefik/Ingress.

### Cosa viene letto dei manifest

Supportati da `podman kube play` (doc podman 5.x): Pod, Deployment,
PersistentVolumeClaim, ConfigMap, Secret, DaemonSet, Job.

Ignorati:
- **Service, Ingress**: il routing lo fa Caddy; il dominio da mettere nel
  Caddyfile è quello scritto nell'Ingress.
- **readinessProbe, startupProbe**: non supportate. `livenessProbe` sì.

`resources.limits.memory` viene applicato come limite cgroup: da mettere
sempre, così un'app che esagera non trascina giù le altre.

### Riavvii

Podman non è un demone, quindi:
- **crash dell'app**: accanto a ogni container gira `conmon` (1-2 MB), che
  alla chiusura applica il `restartPolicy` dello YAML (`Always` per i
  Deployment).
- **reboot della macchina**: ci pensa systemd tramite il `.kube` di Quadlet.

### Perché Caddy e non Traefik

Il punto forte di Traefik è la discovery automatica (Ingress, label Docker).
Con `podman kube play` gli Ingress sono ignorati, quindi la configurazione
andrebbe scritta a mano comunque; a quel punto il Caddyfile è più corto:

```
app1.example.com {
    reverse_proxy 127.0.0.1:8081
}
```

Caddy è anche un normale servizio systemd. Installarlo dal repository
ufficiale Caddy, non da Ubuntu (che ha la 2.6.2 del 2022). In RAM si
equivalgono (entrambi Go, qualche decina di MB).

## Una o più app per server

Ogni app ha il suo YAML, il suo `.kube` e una porta host dedicata. Il
container può ascoltare sulla 80 per tutte: cambia solo il `PublishPort`.

```ini
# ~/.config/containers/systemd/app1.kube
[Kube]
Yaml=app1.yaml
PublishPort=127.0.0.1:8081:80

[Install]
WantedBy=default.target
```

Budget su una micro (602 MB disponibili a vuoto):
- Caddy ~30 MB
- container PHP + SQLite a riposo ~30-80 MB (stima, dipende da immagine e
  processi PHP accesi): usare PHP-FPM con `pm = ondemand`
- → 2-3 app ci stanno in RAM

CPU: a riposo le app PHP consumano zero (è per questo che qui funziona e k3s
no); sotto traffico si dividono 1/8 di core. Adatto a siti con poche visite,
non a traffico costante.

## Deploy (da CI, via SSH)

Ogni deploy fa **sempre** gli stessi passi (idempotente, non solo la prima
volta):

```bash
scp k8s/app1.yaml k8s/app1.kube deploy@host:.config/containers/systemd/
ssh deploy@host 'systemctl --user daemon-reload && systemctl --user restart app1.service'
```

Il restart rilancia `podman kube play` e, con `imagePullPolicy: Always`,
scarica l'immagine nuova.

Non lanciare mai `podman kube play --replace` a mano su un'app gestita da
Quadlet: il pod deve avere un solo proprietario (systemd).

## Preparazione dell'host (una volta)

- Ubuntu 26.04: `podman` dai repo (5.7), Caddy dal repo ufficiale.
- Utente `deploy` (rootless) con la chiave SSH della CI.
- `loginctl enable-linger deploy`: senza, i servizi utente partono solo al
  login e non al boot.
- Le porte < 1024 non sono accessibili rootless: le app pubblicano su
  127.0.0.1:81xx, solo Caddy (di sistema) ascolta su 80/443.
- Firewall: aprire 80/443 anche nella Security List / NSG Oracle.

## Punti aperti

- Generare il blocco Caddyfile dall'Ingress del manifest (host → porta), o
  tenere un file per app in `/etc/caddy/sites/` scritto dal deploy.
- Assegnazione delle porte 81xx alle app (a mano, o registro sul server).
- Login al registry privato per l'utente `deploy` (`podman login`, auth in
  `~/.config/containers/auth.json`).
- Secret: restano nello YAML (kind Secret) o file separato fuori dal repo
  dell'app?
- Log: `journalctl --user -u app1` / `podman logs`.
- Software Oracle sull'immagine Ubuntu (snapd, oracle-cloud-agent): ~50 MB e
  CPU non trascurabile su 1/8 di OCPU; valutare se toglierlo, verificando che
  non serva alla regola di reclaim delle istanze idle.
- Lo `/swapfile` da 2 GB già presente sull'immagine: tenerlo o sostituirlo con
  zram (su KWO lo fa `kwo-tune zram`).
