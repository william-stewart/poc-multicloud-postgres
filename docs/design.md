# Design notes

The detail behind the trade-offs in the [README](../README.md#trade-offs). The README
diagram's source is in [architecture.md](architecture.md).

## Cross-cloud identity

Each cloud reads the other's bucket with no stored keys. AWS IAM trusts GKE's OIDC
issuer, so `pg-replica`'s Kubernetes service account token is exchanged at AWS STS for
a read-only role ([AWS's guide to the same pattern from GCP](https://aws.amazon.com/blogs/security/access-aws-using-a-google-cloud-platform-native-workload-identity/)).
In the other direction, a GCP Workload Identity Federation pool trusts EKS's OIDC
issuer, so `pg-primary`'s token is exchanged at Google STS for read access to the GCS
bucket ([Workload Identity Federation with Kubernetes](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes)).
Each trust accepts only that one service account, and every credential is short-lived.

## An independent copy of the backups in each cloud

`pg-primary` archives to S3 in `us-east-1`. `pg-replica` replays from there and, as a
CloudNativePG replica cluster, runs with `archive_mode=always`: every WAL segment it
replays is archived again to its own GCS bucket in `us-central1`, and it takes its own
nightly base backups there. The GCS copy is written by a GCP identity, with a GCP key,
under `pg-replica/`, so nothing on the GCP side needs AWS to recover, and a promoted
replica keeps archiving to the same place without a change. The cost is a second
archive (about 1,440 WAL segments a day at `archive_timeout` 60s, gzip-compressed) and
a second base backup.

After a failover to `pg-replica`, it has point-in-time recovery from the first GCS base
backup on. If its volume is also lost, a new cluster can be restored from GCS.

Two limits of this design. The GCS copy can only be as current as the replica: if the
replica stops replaying, the GCS archive stops too, so replication lag is also the age
of the GCP backups. And Barman won't archive into a prefix that already holds another
cluster's history, so a cluster restored from GCS must archive under a new name (a
different `serverName`, or a new bucket), never back into `pg-replica/` or `pg-primary/`.

## Shared settings and module interfaces

`infra/modules/settings` holds the values both clouds share (names, regions, zones,
address plan, Kubernetes version, node OS, labels), and validation rejects overlapping
address ranges. Each cloud has its own module per concern (`network`, `network-lookup`,
`cluster`) rather than one module with a `cloud` switch, so each stack needs one
provider and one set of credentials. OpenTofu has no way to declare a module interface,
so two checks keep the AWS and GCP modules interchangeable for callers:
`scripts/check_module_contracts.py` checks that the inputs and outputs in each
`contract.json` are declared, and `infra/tests/contracts` checks the values the outputs
produce.

## Separate state per layer, joined by data sources

Later stacks find the layers below them by name (`network-lookup`, EKS and KMS data
sources), not through `terraform_remote_state`, so a stack needs only read access in the
cloud, never another stack's state file.
