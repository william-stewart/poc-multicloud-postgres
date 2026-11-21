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
  4. Turn every CRD that Flux and the pinned charts install into a strict JSON
     schema (unknown fields rejected), and validate all of the above with
     kubeconform against those schemas, Kubernetes 1.36, and a pinned CRD
     catalog as a fallback.


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


def strict_schema(node):
    """Convert a CRD openAPIV3Schema into a JSON schema that rejects unknown fields."""
    if isinstance(node, list):
        return [strict_schema(n) for n in node]
    if not isinstance(node, dict):
        return node
    node = {k: strict_schema(v) for k, v in node.items()}
    if node.pop("x-kubernetes-int-or-string", False):
        node.pop("type", None)
        node["oneOf"] = [{"type": "string"}, {"type": "integer"}]
    if node.pop("nullable", False) and isinstance(node.get("type"), str):
        node["type"] = [node["type"], "null"]
    preserve = node.pop("x-kubernetes-preserve-unknown-fields", False)
    if "properties" in node and "additionalProperties" not in node and not preserve:
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


def render_cloud(cloud: str, schema_dir: Path, helm_releases: dict[str, list[dict]]) -> list[tuple[str, str, bool]]:
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
        helm_releases.setdefault(cloud, []).extend(d for d in docs if d.get("kind") == "HelmRelease")
        for label, manifests in render_helm_releases(docs, cloud):
            collect_crd_schemas(load_docs(manifests), schema_dir)
            # Charts may render custom resources whose CRDs nothing here
            # installs; those are skipped, everything else is strict.
            outputs.append((label, manifests, True))

    for source, env in envs.items():
        if unused := sorted(env.keys() - used_by_file.get(source, set())):
            raise Failure(f"k8s/clusters/{cloud}/{source}.example.env lists variables nothing uses: {', '.join(unused)}")
    return outputs


def main() -> int:
    try:
        check_flux_version()
        helm_releases: dict[str, list[dict]] = {}
        with tempfile.TemporaryDirectory() as tmp:
            schema_dir = Path(tmp)
            # Render everything first, so the CRDs of every chart are known
            # before validating the custom resources that use them.
            outputs = {cloud: render_cloud(cloud, schema_dir, helm_releases) for cloud in CLOUDS}
            print(f"strict schemas generated from installed CRDs: {sum(1 for _ in schema_dir.rglob('*.json'))}")
            for cloud, items in outputs.items():
                print(f"== {cloud}")
                for label, manifests, ignore_missing in items:
                    kubeconform(manifests, label, schema_dir, ignore_missing)
        check_bootstrap_matches(helm_releases)
    except Failure as e:
        print(f"k8s validation failed:\n{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
