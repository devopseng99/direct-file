# Direct File Kubernetes Deployment

IRS Direct File application deployment on a memory-constrained 2-node Kubernetes cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    direct-file namespace                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────┐                     │
│  │   PostgreSQL    │    │     Redis       │                     │
│  │   (StatefulSet) │    │  (StatefulSet)  │                     │
│  │   Port: 5432    │    │   Port: 6379    │                     │
│  │   512Mi limit   │    │   256Mi limit   │                     │
│  └────────┬────────┘    └────────┬────────┘                     │
│           │                      │                               │
│           └──────────┬───────────┘                               │
│                      │                                           │
│           ┌──────────▼──────────┐                               │
│           │   Local PVs         │                               │
│           │   mgplcb05 node     │                               │
│           │   /opt/k8s-pers/vol1│                               │
│           └─────────────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

## Cluster Details

- **Control Plane**: mgplcb04
- **Worker Node**: mgplcb05 (192.168.29.147)
- **Memory**: ~8GB per node, 95% committed on mgplcb05
- **Storage Class**: `my-local-storage`
- **PV Base Path**: `/opt/k8s-pers/vol1/`

## Prerequisites

1. Kubernetes cluster access (kubectl configured)
2. Helm 3.x installed
3. SSH access to mgplcb05 with key `~/.ssh/id_rsa_devops_ssh`

## Deployment Steps

### 1. Provision Node Directories

```bash
bash scripts/provision-node-dirs.sh 192.168.29.147
```

This creates:
- `/opt/k8s-pers/vol1/psql-direct-file` (999:999)
- `/opt/k8s-pers/vol1/redis-direct-file` (999:0)

### 2. Create Kubernetes Secrets

```bash
bash scripts/setup-secrets.sh
```

This creates:
- `direct-file-postgres-secret`
- `direct-file-redis-secret`
- `direct-file-database-url-secret`
- `direct-file-app-secret`

### 3. Dry Run (Validate Templates)

```bash
helm upgrade --install direct-file ./my-direct-file-helm/direct-file-chart \
  --namespace=direct-file --create-namespace \
  -f overrides.yaml --dry-run --debug
```

### 4. Deploy

```bash
helm upgrade --install direct-file ./my-direct-file-helm/direct-file-chart \
  --namespace=direct-file --create-namespace \
  -f overrides.yaml
```

Or use the convenience script:
```bash
source .run0apply
```

### 5. Verify Deployment

```bash
kubectl get pods,pvc,svc -n direct-file
```

Expected output:
```
NAME                                    READY   STATUS    RESTARTS   AGE
pod/direct-file-postgresql-0           1/1     Running   0          5m
pod/direct-file-redis-0                1/1     Running   0          5m

NAME                                          STATUS   VOLUME                   CAPACITY   ACCESS MODES
persistentvolumeclaim/psql-direct-file-claim0   Bound    psql-direct-file-claim0   10Gi       RWO
persistentvolumeclaim/redis-direct-file-claim0  Bound    redis-direct-file-claim0  2Gi        RWO

NAME                             TYPE        CLUSTER-IP       PORT(S)
service/direct-file-postgresql   ClusterIP   10.43.x.x        5432/TCP
service/direct-file-redis        ClusterIP   10.43.x.x        6379/TCP
```

### 6. Apply Network Policies

```bash
kubectl apply -f manifests/
```

## Troubleshooting

### DiskPressure Taint

If pods are not scheduling due to DiskPressure:
```bash
kubectl describe node mgplcb05 | grep -A5 Conditions
```

Wait ~5 minutes for `evictionPressureTransitionPeriod` to clear.

### View Logs

```bash
# PostgreSQL
kubectl logs -f statefulset/direct-file-postgresql -n direct-file

# Redis
kubectl logs -f statefulset/direct-file-redis -n direct-file
```

### Access PostgreSQL

```bash
kubectl exec -it direct-file-postgresql-0 -n direct-file -- psql -U postgres -d directfile
```

### Access Redis

```bash
kubectl exec -it direct-file-redis-0 -n direct-file -- redis-cli -a $(kubectl get secret direct-file-redis-secret -n direct-file -o jsonpath='{.data.redis-password}' | base64 -d)
```

### View Secrets

```bash
bash scripts/setup-secrets.sh --show
```

### Rotate Secrets

```bash
bash scripts/setup-secrets.sh --rotate
# Then restart pods
kubectl rollout restart statefulset/direct-file-postgresql -n direct-file
kubectl rollout restart statefulset/direct-file-redis -n direct-file
```

## Logging Configuration

All components are configured with logging set to **WARN** or higher (INFO is OFF):

- **PostgreSQL**: `log_min_messages: WARNING`, `log_statement: none`
- **Redis**: `loglevel warning`
- **API** (when enabled): `LOG_LEVEL: WARN`, all Spring/Hibernate loggers at WARN

## Resource Limits

| Component  | Memory Limit | CPU Limit |
|------------|--------------|-----------|
| PostgreSQL | 512Mi        | 500m      |
| Redis      | 256Mi        | 200m      |
| API        | 1Gi          | 1000m     |
| Client     | 256Mi        | 200m      |

## Files

```
direct-file/
├── .gitignore
├── .run0apply                    # Helm install convenience script
├── DEPLOYMENT.md                 # This file
├── overrides.yaml                # Production values (no secrets!)
├── manifests/
│   ├── netpol-allow-cfd.yaml    # Cloudflare tunnel ingress
│   └── netpol-db-internal.yaml  # Database internal-only
├── my-direct-file/               # Upstream source (cloned)
├── my-direct-file-helm/          # Helm chart
│   └── direct-file-chart/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── ingress.yaml
│           ├── NOTES.txt
│           ├── postgresql.yaml
│           ├── redis.yaml
│           ├── serviceaccount.yaml
│           └── pvs/
│               ├── postgres-pv.yaml
│               ├── postgres-pvc.yaml
│               ├── redis-pv.yaml
│               └── redis-pvc.yaml
└── scripts/
    ├── provision-node-dirs.sh    # Create PV directories on nodes
    └── setup-secrets.sh          # Create K8s secrets
```

## Cloudflare Tunnel (TODO)

Configure Cloudflare tunnel to expose services:
- Direct File API: `direct-file-api.direct-file.svc.cluster.local:8080`
- Direct File Client: `direct-file-client.direct-file.svc.cluster.local:80`

## Upstream Repository

- **Original**: https://github.com/IRS-Public/direct-file
- **Private Fork**: https://github.com/devopseng99/my-direct-file
