#!/usr/bin/env python3
"""Validate the Kubernetes layer (k8s/) without a cluster.

For each cloud:
  1. Build k8s/clusters/<cloud> (Flux install and sync) with kustomize.
  2. Find the Flux Kustomizations it defines (platform, data, ...). Build each
     one's path, check that every ${VAR} it uses is listed in the
     <name>.example.env files of the ConfigMaps it substitutes from (and that
     every listed variable is used), and substitute the examples the way
     Flux's postBuild does.
  3. Render every HelmRelease with `helm template`, using its pinned chart
     version and its merged values (valuesFrom ConfigMaps, then spec.values),
     and check each values key against the chart's values.schema.json. Many
     charts' schemas list every key but still accept unknown ones, so a typo
     or a key removed in a new chart version would otherwise be ignored.
  4. Turn every CRD that Flux, the pinned charts and the pinned Cilium release
     (CiliumNetworkPolicy, fetched by commit) install into a strict JSON
     schema (unknown fields rejected), and validate all of the above with
     kubeconform against those schemas, Kubernetes 1.36, and a pinned CRD
     catalog as a fallback.

  5. Scan the manifests Flux applies (each cluster's Flux setup and each Flux
     Kustomization, rendered) with checkov's Kubernetes checks. Scanning the
     rendered output is deterministic, unlike checkov's own kustomize
     scanner, whose overlay heuristics don't fit this layout. Accepted
     findings are recorded as checkov.io/skip annotations on the objects.
     The charts' own rendered manifests are upstream code and not scanned.

It also checks that bootstrap.sh installs the versions Flux manages, and that
the Flux images pinned by digest match the generated Flux manifests.

Runs as a pre-commit hook (which provides PyYAML) and from `make validate`.
Needs kustomize, helm and kubeconform on PATH. Charts are cached under
$XDG_CACHE_HOME (default ~/.cache)/poc-multicloud-postgres/charts.
"""

from __future__ import annotations

import copy
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CLOUDS = ("aws", "gcp")
KUBERNETES_VERSION = "1.36.0"  # keep in step with the settings module
# Fallback CRD schemas, pinned to a commit.
CRD_CATALOG = (
    "https://raw.githubusercontent.com/datreeio/CRDs-catalog/"
    "784ec895547a36e548e6810b41f27baade3a0890/"
    "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
)
VAR = re.compile(r"\$\{([^}]*)\}")
PLAIN_VAR = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "poc-multicloud-postgres" / "charts"


class Failure(Exception):
    pass


def run(cmd: list[str], stdin: str | None = None) -> str:
    result = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if result.returncode != 0:
        raise Failure(f"$ {' '.join(cmd)}\n{result.stdout}{result.stderr}".rstrip())
    return result.stdout


def load_docs(text: str) -> list[dict]:
    return [d for d in yaml.safe_load_all(text) if d]


# --- Variables -------------------------------------------------------------


def read_env(path: Path) -> dict[str, str]:
    if not path.exists():
        raise Failure(f"{path.relative_to(ROOT)} is missing")
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def substitute(text: str, env: dict[str, str], where: str) -> tuple[str, set[str]]:
    used = set()
    for match in VAR.finditer(text):
        name = match.group(1)
        if not PLAIN_VAR.match(name):
            raise Failure(f"{where}: only plain ${{VAR}} substitutions are supported, found ${{{name}}}")
        used.add(name)
    if missing := sorted(used - env.keys()):
        raise Failure(f"{where}: uses variables not listed in its .example.env files: {', '.join(missing)}")
    return VAR.sub(lambda m: env[m.group(1)], text), used


# --- Schemas from CRDs -----------------------------------------------------


COMBINATORS = ("anyOf", "oneOf", "allOf", "not")


def strict_schema(node, strict: bool = True):
    """Convert a CRD openAPIV3Schema into a JSON schema that rejects unknown fields.

    Branches of anyOf/oneOf/allOf/not express constraints (for example "at
    least one of ingress or egress"), not the object's shape, so nothing
    inside them is made strict: a branch listing only `ingress` must not
    reject `endpointSelector`.
    """
    if isinstance(node, list):
        return [strict_schema(n, strict) for n in node]
    if not isinstance(node, dict):
        return node
    node = {k: strict_schema(v, strict and k not in COMBINATORS) for k, v in node.items()}
    if node.pop("x-kubernetes-int-or-string", False):
        node.pop("type", None)
        node["oneOf"] = [{"type": "string"}, {"type": "integer"}]
    if node.pop("nullable", False) and isinstance(node.get("type"), str):
        node["type"] = [node["type"], "null"]
    preserve = node.pop("x-kubernetes-preserve-unknown-fields", False)
    if strict and "properties" in node and "additionalProperties" not in node and not preserve:
        node["additionalProperties"] = False
    return node


def collect_crd_schemas(docs: list[dict], schema_dir: Path) -> None:
    for crd in (d for d in docs if d.get("kind") == "CustomResourceDefinition"):
        group = crd["spec"]["group"]
        kind = crd["spec"]["names"]["kind"].lower()
        for version in crd["spec"]["versions"]:
            schema = version.get("schema", {}).get("openAPIV3Schema")
            if not schema:
                continue
            schema = strict_schema(copy.deepcopy(schema))
            # apiVersion, kind and metadata are always allowed at the root.
            schema.setdefault("properties", {}).update(
                {"apiVersion": {"type": "string"}, "kind": {"type": "string"}, "metadata": {"type": "object"}}
            )
            path = schema_dir / group / f"{kind}_{version['name']}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(schema))


# The commit each Cilium release tag points to. Tags can be moved, so the CRDs
# are fetched by commit. To upgrade Cilium, add the new tag's commit:
#   git ls-remote https://github.com/cilium/cilium 'refs/tags/v<version>^{}'
CILIUM_COMMITS = {
    "1.20.5": "150121410c147fad575ac5dcbce6de923be69042",
}


def cilium_crds(version: str) -> list[dict]:
    """CiliumNetworkPolicy CRDs as the pinned Cilium release installs them.

    The Cilium operator creates its CRDs at runtime from copies embedded in
    the release, so they aren't in the chart; fetch them from the release's
    commit.
    """
    commit = CILIUM_COMMITS.get(version)
    if commit is None:
        raise Failure(
            f"Cilium {version} has no pinned commit in CILIUM_COMMITS (scripts/validate_k8s.py); add the commit "
            f"from: git ls-remote https://github.com/cilium/cilium 'refs/tags/v{version}^{{}}'"
        )
    docs = []
    for name in ("ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"):
        cached = CACHE / f"cilium-{commit}-{name}.yaml"
        if not cached.exists():
            CACHE.mkdir(parents=True, exist_ok=True)
            url = f"https://raw.githubusercontent.com/cilium/cilium/{commit}/pkg/k8s/apis/cilium.io/client/crds/v2/{name}.yaml"
            run(["curl", "-fsSL", "-o", str(cached), url])
        docs += load_docs(cached.read_text())
    return docs


def kubeconform(manifests: str, label: str, schema_dir: Path, ignore_missing: bool = False) -> None:
    cmd = [
        "kubeconform", "-strict", "-summary",
        "-kubernetes-version", KUBERNETES_VERSION,
        "-schema-location", str(schema_dir) + "/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json",
        "-schema-location", "default",
        "-schema-location", CRD_CATALOG,
        # No JSON schema exists for CRD objects themselves; the CRDs here are
        # vendored from releases (Flux, charts), and turned into schemas above.
        "-skip", "CustomResourceDefinition",
    ]
    if ignore_missing:
        cmd.append("-ignore-missing-schemas")
    out = run(cmd, stdin=manifests)
    print(f"  {label}: {out.strip().splitlines()[-1].replace('parsing stdin - ', '')}")


def checkov_scan(outputs: dict[str, list[tuple[str, str, bool]]]) -> None:
    """Run checkov's Kubernetes checks on the manifests Flux applies."""
    with tempfile.TemporaryDirectory() as tmp:
        for cloud, items in outputs.items():
            for i, (label, manifests, from_chart) in enumerate(items):
                if not from_chart:
                    (Path(tmp) / f"{cloud}-{i:02d}.yaml").write_text(manifests)
        # Run outside the repo, so its .checkov.yaml (for OpenTofu) doesn't apply.
        result = subprocess.run(
            ["checkov", "-d", ".", "--framework", "kubernetes", "-o", "json"],
            cwd=tmp, capture_output=True, text=True,
        )
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise Failure(f"checkov didn't produce a report:\n{result.stdout}{result.stderr}") from None
    results = (report[0] if isinstance(report, list) else report).get("results", {})
    failed = results.get("failed_checks", [])
    print(
        f"checkov on the manifests Flux applies: {len(results.get('passed_checks', []))} passed, "
        f"{len(failed)} failed, {len(results.get('skipped_checks', []))} skipped (recorded exceptions)"
    )
    if failed:
        lines = [f"  {c['check_id']} {c['resource']}: {c['check_name']}" for c in failed]
        raise Failure("checkov findings in the manifests Flux applies:\n" + "\n".join(lines))


# --- Helm ------------------------------------------------------------------


def deep_merge(base: dict, override: dict) -> dict:
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def pull_chart(repo: dict, chart: str, version: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    cached = CACHE / f"{chart}-{version}.tgz"
    if cached.exists():
        return cached
    url = repo["spec"]["url"]
    if repo["spec"].get("type") == "oci":
        cmd = ["helm", "pull", f"{url.rstrip('/')}/{chart}", "--version", version, "-d", str(CACHE)]
    else:
        cmd = ["helm", "pull", chart, "--repo", url, "--version", version, "-d", str(CACHE)]
    run(cmd)
    if not cached.exists():  # OCI charts may be saved without a leading "v"
        matches = list(CACHE.glob(f"{chart}-{version.lstrip('v')}.tgz"))
        if not matches:
            raise Failure(f"helm pull didn't produce {cached.name}")
        matches[0].rename(cached)
    return cached


def chart_schema(chart: Path, name: str) -> dict | None:
    with tarfile.open(chart) as tar:
        try:
            member = tar.extractfile(f"{name}/values.schema.json")
        except KeyError:
            return None
        return json.load(member) if member else None


def unknown_keys(values, schema, root: dict, path: str = "") -> list[str]:
    """Value keys the schema doesn't declare. Free-form maps (no properties) are not checked."""
    while isinstance(schema, dict) and "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        schema = node
    if not isinstance(values, dict) or not isinstance(schema, dict) or "properties" not in schema:
        return []
    found = []
    for key, value in values.items():
        key_path = f"{path}.{key}" if path else key
        if key not in schema["properties"]:
            found.append(key_path)
        else:
            found += unknown_keys(value, schema["properties"][key], root, key_path)
    return found


def render_helm_releases(docs: list[dict], cloud: str) -> list[tuple[str, str]]:
    """Render every HelmRelease; return (label, manifests) pairs."""
    repos = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in docs if d.get("kind") == "HelmRepository"}
    configmaps = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in docs if d.get("kind") == "ConfigMap"}
    rendered = []
    for hr in (d for d in docs if d.get("kind") == "HelmRelease"):
        name, ns = hr["metadata"]["name"], hr["metadata"]["namespace"]
        spec = hr["spec"]["chart"]["spec"]
        ref = spec["sourceRef"]
        repo = repos.get((ref.get("namespace", ns), ref["name"]))
        if repo is None:
            raise Failure(f"{cloud}: HelmRelease {ns}/{name} refers to missing HelmRepository {ref['name']}")

        values: dict = {}
        for source in hr["spec"].get("valuesFrom", []):
            cm = configmaps.get((ns, source["name"]))
            if cm is None:
                raise Failure(f"{cloud}: HelmRelease {ns}/{name} refers to missing ConfigMap {source['name']}")
            values = deep_merge(values, yaml.safe_load(cm["data"][source.get("valuesKey", "values.yaml")]) or {})
        values = deep_merge(values, hr["spec"].get("values") or {})

        chart = pull_chart(repo, spec["chart"], spec["version"])
        schema = chart_schema(chart, spec["chart"])
        if schema is not None and (unknown := unknown_keys(values, schema, schema)):
            raise Failure(
                f"{cloud}: HelmRelease {ns}/{name} sets keys that {spec['chart']} {spec['version']} "
                f"doesn't define: {', '.join(unknown)}"
            )
        with tempfile.NamedTemporaryFile("w", suffix=".yaml") as f:
            yaml.safe_dump(values, f)
            f.flush()
            manifests = run([
                "helm", "template", hr["spec"].get("releaseName", name), str(chart),
                "--namespace", ns, "--kube-version", KUBERNETES_VERSION, "-f", f.name,
            ])
        rendered.append((f"helm template {ns}/{name} ({spec['chart']} {spec['version']})", manifests))
    return rendered


# --- Consistency checks ----------------------------------------------------


def read_tool_versions(path: Path) -> dict[str, str]:
    pairs = (line.split() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#"))
    return {p[0]: p[1] for p in pairs if len(p) == 2}


def check_flux_version() -> None:
    """The committed Flux manifests match the pinned flux CLI and the digest pins."""
    gotk = (ROOT / "k8s" / "flux" / "gotk-components.yaml").read_text()
    pinned = read_tool_versions(ROOT / ".tool-versions").get("flux")
    header = re.search(r"^# Flux Version: v(\S+)", gotk, re.MULTILINE)
    if not pinned or not header:
        raise Failure("can't read the Flux version from .tool-versions or k8s/flux/gotk-components.yaml")
    if header.group(1) != pinned:
        raise Failure(f"k8s/flux/gotk-components.yaml is Flux {header.group(1)} but .tool-versions pins {pinned}; run make flux-manifests")
    print(f"k8s/flux/gotk-components.yaml matches .tool-versions (Flux {pinned})")

    # The digest overrides must be for exactly the images and tags upstream
    # ships, so an upgrade can't keep running old images under new manifests.
    upstream = dict(m.groups() for m in re.finditer(r"image: (\S+):(\S+)", gotk))
    kustomization = yaml.safe_load((ROOT / "k8s" / "flux" / "kustomization.yaml").read_text())
    pinned_images = {i["name"]: i for i in kustomization.get("images", [])}
    for name, tag in upstream.items():
        image = pinned_images.get(name)
        if image is None or not str(image.get("digest", "")).startswith("sha256:"):
            raise Failure(f"k8s/flux/kustomization.yaml doesn't pin {name} by digest")
        if image.get("newTag") != tag:
            raise Failure(
                f"k8s/flux/kustomization.yaml pins {name} {image.get('newTag')} but gotk-components.yaml ships {tag}; "
                "update its newTag and digest"
            )
    if extra := sorted(pinned_images.keys() - upstream.keys()):
        raise Failure(f"k8s/flux/kustomization.yaml pins images Flux no longer ships: {', '.join(extra)}")
    print(f"Flux controller images pinned by digest ({len(upstream)})")


# Objects whose deletion would take down cluster networking (and with it Flux)
# or delete a database. Flux must never prune them.
NEVER_PRUNE = {
    ("HelmRelease", "kube-system", "cilium"),
    ("HelmRelease", "kube-system", "coredns"),
}
NEVER_PRUNE_KINDS = {("postgresql.cnpg.io", "Cluster")}


def check_never_pruned(docs: list[dict], where: str) -> None:
    """Objects Flux must never delete carry kustomize.toolkit.fluxcd.io/prune: disabled."""
    for d in docs:
        meta = d.get("metadata", {})
        key = (d.get("kind"), meta.get("namespace"), meta.get("name"))
        group = d.get("apiVersion", "").split("/")[0]
        if key not in NEVER_PRUNE and (group, d.get("kind")) not in NEVER_PRUNE_KINDS:
            continue
        if (meta.get("annotations") or {}).get("kustomize.toolkit.fluxcd.io/prune") != "disabled":
            raise Failure(
                f"{where}: {key[0]} {key[1]}/{key[2]} must have the annotation "
                "kustomize.toolkit.fluxcd.io/prune: disabled, or removing it from git deletes it"
            )


def check_postgres_images(clusters: list[tuple[str, dict]]) -> None:
    """Every CloudNativePG Cluster runs the same PostgreSQL image, pinned by digest.

    The replica replays the primary's WAL, which only works on the same major
    version; a mismatch would otherwise surface only when replay fails.
    """
    images = {}
    for where, cluster in clusters:
        name = f"{where}: Cluster {cluster['metadata']['name']}"
        image = cluster.get("spec", {}).get("imageName")
        if not image or not re.search(r"@sha256:[0-9a-f]{64}$", image):
            raise Failure(f"{name} must set spec.imageName pinned by digest (see k8s/data/components/postgres-image)")
        images[name] = image
    if len(set(images.values())) > 1:
        lines = "\n".join(f"  {n}: {i}" for n, i in images.items())
        raise Failure(f"CloudNativePG Clusters run different PostgreSQL images; primary and replica must match:\n{lines}")
    if images:
        print(f"CloudNativePG Clusters share one digest-pinned PostgreSQL image ({len(images)})")


def check_bootstrap_matches(helm_releases: dict[str, list[dict]]) -> None:
    """bootstrap.sh installs Cilium (and CoreDNS on EKS) at the versions Flux manages."""
    script = (ROOT / "k8s" / "bootstrap.sh").read_text()
    for release, variable in {"cilium": "CILIUM_VERSION", "coredns": "COREDNS_VERSION"}.items():
        match = re.search(rf'^{variable}="([^"]+)"', script, re.MULTILINE)
        if not match:
            raise Failure(f"k8s/bootstrap.sh: {variable} not found")
        for cloud, releases in helm_releases.items():
            hr = next((d for d in releases if d["metadata"]["name"] == release), None)
            if hr is None:
                continue  # e.g. CoreDNS is only managed on EKS
            pinned = hr["spec"]["chart"]["spec"]["version"]
            if pinned != match.group(1):
                raise Failure(
                    f"k8s/bootstrap.sh installs {release} {match.group(1)} but the {cloud} HelmRelease pins "
                    f"{pinned}; Flux would immediately change it"
                )
        print(f"bootstrap.sh {release} version matches the HelmReleases ({match.group(1)})")


# --- Main ------------------------------------------------------------------


def flux_kustomizations(docs: list[dict]) -> list[dict]:
    """Flux Kustomizations other than flux-system, parents before dependents."""
    ks = {
        d["metadata"]["name"]: d for d in docs
        if d.get("kind") == "Kustomization"
        and d.get("apiVersion", "").startswith("kustomize.toolkit.fluxcd.io/")
        and d["metadata"]["name"] != "flux-system"
    }
    ordered: list[dict] = []

    def visit(name: str, seen: tuple = ()) -> None:
        if name in seen:
            raise Failure(f"Flux Kustomizations have a dependency cycle: {' -> '.join(seen + (name,))}")
        if any(k["metadata"]["name"] == name for k in ordered):
            return
        for dep in ks[name]["spec"].get("dependsOn", []):
            if dep["name"] not in ks:
                raise Failure(f"Flux Kustomization {name} depends on unknown {dep['name']}")
            visit(dep["name"], seen + (name,))
        ordered.append(ks[name])

    for name in ks:
        visit(name)
    return ordered


def render_cloud(
    cloud: str, schema_dir: Path, helm_releases: dict[str, list[dict]], pg_clusters: list[tuple[str, dict]]
) -> list[tuple[str, str, bool]]:
    """Build and render everything for one cloud; return (label, manifests, ignore_missing)."""
    cluster_dir = ROOT / "k8s" / "clusters" / cloud
    clusters = run(["kustomize", "build", str(cluster_dir)])
    cluster_docs = load_docs(clusters)
    collect_crd_schemas(cluster_docs, schema_dir)
    outputs = [(f"clusters/{cloud}", clusters, False)]

    used_by_file: dict[str, set[str]] = {}
    envs: dict[str, dict[str, str]] = {}
    for ks in flux_kustomizations(cluster_docs):
        name = ks["metadata"]["name"]
        path = ks["spec"]["path"].removeprefix("./")
        env: dict[str, str] = {}
        sources = [s["name"] for s in ks["spec"].get("postBuild", {}).get("substituteFrom", [])]
        for source in sources:
            envs.setdefault(source, read_env(cluster_dir / f"{source}.example.env"))
            env.update(envs[source])
        built, used = substitute(run(["kustomize", "build", str(ROOT / path)]), env, f"{cloud}/{name} ({path})")
        for source in sources:
            used_by_file.setdefault(source, set()).update(used & envs[source].keys())
        outputs.append((f"{cloud}/{name} ({path})", built, False))

        docs = load_docs(built)
        check_never_pruned(docs, f"{cloud}/{name} ({path})")
        pg_clusters.extend(
            (f"{cloud}/{name}", d) for d in docs
            if d.get("kind") == "Cluster" and d.get("apiVersion", "").startswith("postgresql.cnpg.io/")
        )
        releases =[d for d in docs if d.get("kind") == "HelmRelease"]
        helm_releases.setdefault(cloud, []).extend(releases)
        for hr in releases:
            if hr["metadata"]["name"] == "cilium":
                collect_crd_schemas(cilium_crds(hr["spec"]["chart"]["spec"]["version"]), schema_dir)
        for label, manifests in render_helm_releases(docs, cloud):
            collect_crd_schemas(load_docs(manifests), schema_dir)
            # Charts may render custom resources whose CRDs nothing here
            # installs; those are skipped, everything else is strict.
            outputs.append((label, manifests, True))

    # Removing or renaming these would make Flux leave the running release
    # unmanaged (prune is disabled), so make it a deliberate change here too.
    required = {("kube-system", "cilium")} | ({("kube-system", "coredns")} if cloud == "aws" else set())
    present = {(hr["metadata"]["namespace"], hr["metadata"]["name"]) for hr in helm_releases.get(cloud, [])}
    if missing := sorted(required - present):
        raise Failure(f"{cloud}: HelmRelease(s) missing: {', '.join('/'.join(m) for m in missing)}")

    for source, env in envs.items():
        if unused := sorted(env.keys() - used_by_file.get(source, set())):
            raise Failure(f"k8s/clusters/{cloud}/{source}.example.env lists variables nothing uses: {', '.join(unused)}")
    return outputs


def main() -> int:
    try:
        check_flux_version()
        helm_releases: dict[str, list[dict]] = {}
        pg_clusters: list[tuple[str, dict]] = []
        with tempfile.TemporaryDirectory() as tmp:
            schema_dir = Path(tmp)
            # Render everything first, so the CRDs of every chart are known
            # before validating the custom resources that use them.
            outputs = {cloud: render_cloud(cloud, schema_dir, helm_releases, pg_clusters) for cloud in CLOUDS}
            check_postgres_images(pg_clusters)
            print(f"strict schemas generated from installed CRDs: {sum(1 for _ in schema_dir.rglob('*.json'))}")
            for cloud, items in outputs.items():
                print(f"== {cloud}")
                for label, manifests, ignore_missing in items:
                    kubeconform(manifests, label, schema_dir, ignore_missing)
            checkov_scan(outputs)
        check_bootstrap_matches(helm_releases)
    except Failure as e:
        print(f"k8s validation failed:\n{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
