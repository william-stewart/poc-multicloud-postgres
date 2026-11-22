# End-to-end test on a local cluster

`make e2e` runs the data layer on a local single-node cluster, Rancher Desktop by
default, then breaks it on purpose and measures what happens. It uses the real
`k8s/data` manifests and the chart versions and values that Flux installs. A local S3
server (SeaweedFS) stands in for both clouds' object storage. Run it before changing
`k8s/data` or the operator versions, and before a live drill.

```sh
make e2e                    # about 20-30 minutes, then removes what it installed
E2E_KEEP=1 make e2e         # leave it running for inspection; make e2e-clean removes it
```

| # | Scenario | Checked | Measured |
| --- | --- | --- | --- |
| 1 | Replication | A row written on `pg-primary` reaches `pg-replica` | Lag after a WAL switch |
| 2 | Restore from the GCP copy | Point-in-time restore from `pg-replica`'s archive alone lands exactly on the target time | Restore time |
| 3 | Kill the primary pod | The other instance takes writes; no committed row is lost; archiving continues | Failover time |
| 4 | Object store outage | Writes continue; CloudNativePG reports archiving failing; the replica catches up afterwards | Time to detect, time to catch up |
| 5 | Planned switchover and back | Promotion tokens, no row lost, replication in both directions | Switchover time each way |
| 6 | Unplanned failover | The fenced primary refuses connections, and still does 60s later; `pg-replica` takes writes | Failover time, rows lost (RPO) |

Each run writes its results to `evidence/e2e/<UTC time>.md`; commit that file as the
record of the run. A failed run also saves cluster state and logs under
`test/e2e/results/` (gitignored).

How it differs from production, and so what it doesn't prove: the overlays in
`test/e2e/manifests` give every object store a static key in place of IRSA, GKE
Workload Identity and the two federations. They also use local volumes, smaller
resources, and preferred rather than required anti-affinity, because there is one
node. Cilium network policies aren't applied. Both archives live on one S3 server, and
both clusters share one node and one operator. Everything else, including the
distributed topology and `archive_timeout`, is what production runs. `make validate`
renders these overlays and checks them against the CRD schemas, so a change to
`k8s/data` that breaks them fails there first.

The script only runs against a context whose API server is on `localhost`, so it
can't touch a cloud cluster. It needs `kubectl`, `helm`, `kustomize`, `python3` and
`openssl`. Give Rancher Desktop's VM 4 CPUs and 8 GB (Preferences > Virtual Machine);
with less, the four PostgreSQL pods may wait for resources.

## Watching a run in Grafana

`E2E_MONITORING=1` also installs Prometheus and Grafana (`k8s/monitoring`) before the
databases, so the dashboard covers the whole run:

```sh
E2E_MONITORING=1 E2E_KEEP=1 make e2e   # in one terminal; keep it so Grafana outlives the run
make e2e-grafana                       # in another, once the run prints "Dashboard:"
open http://localhost:3000/d/postgres-dr
```

Grafana opens read-only without a login. The admin password is in the
`monitoring/kube-prometheus-stack-grafana` Secret. Give the VM about 10 GB with
monitoring on.

The screenshot in the [README](../README.md#testing-failure-scenarios) shows a run
opened this way. The run marks each scenario on every panel as a region between dashed lines; hover over
a line to see its name, or turn the marks off with the *End-to-end test scenarios*
toggle. `run.sh` adds them through its own port-forward to Grafana, with the admin
login from that Secret. If it can't reach Grafana, the run carries on unmarked.

The dashboard, *PostgreSQL across clouds: recovery point and failover*, uses only
metrics CloudNativePG and the Barman Cloud plugin already serve on each instance's
port 9187. One PodMonitor scrapes them every 10s. Each scenario has its own shape:

| Panel | What it shows | Where the scenarios show up |
| --- | --- | --- |
| Role of each Cluster | Primary, replica, no primary (should be primary, nothing accepts writes) or fenced | 3: a few seconds of no primary. 5: the roles swap and swap back. 6: `pg-replica` turns primary, `pg-primary` fenced |
| PostgreSQL up, per instance | Whether each pod's PostgreSQL answers | 3: the killed pod drops out and comes back |
| How long closed WAL has waited for the archive | Per Cluster: 0 unless a closed segment is waiting, then the time since the archive last accepted one. An idle database stays at 0 | 4: the primary's line climbs until the store is back |
| WAL segments the replica's archive trails the primary's | The cross-cloud lag, for whichever Cluster is in replica mode | 1: it rises until the replica replays the new segment. 4 stops both archives, so it stays flat |
| WAL segments waiting to be archived | `.ready` files piling up on the WAL volume | 4: they pile up during the outage, then drain |
| Failed archive attempts | Per minute | 4 |
| Last base backup, restorable back to | Per archive, from the Barman Cloud plugin: how long ago the newest backup completed, and the earliest point it can restore to | 0: both archives get their first backup |
| Rows written per minute | Inserts, updates and deletes in `app`, per Cluster | Where each scenario's writes land |

In the end-to-end test both archives are the same local S3 server and replication
crosses no network, so the lag is shorter than on the clouds. Flux installs the same
stack and dashboard on EKS and GKE (see [Dashboard](deploy.md#dashboard)).
