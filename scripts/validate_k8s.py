#!/usr/bin/env python3
"""Validate the Kubernetes layer (k8s/) without a cluster.

For each cloud:
  1. Build k8s/clusters/<cloud> (Flux install and sync) with kustomize and
     validate it with kubeconform.
  2. Build k8s/platform/<cloud>, check that every ${VAR} it uses is listed in
     k8s/clusters/<cloud>/cluster-vars.example.env (and vice versa),
     substitute the example values the way Flux's postBuild does, and validate
     the result with kubeconform.
  3. Render every HelmRelease with `helm template`, using its pinned chart
     version and its merged values (valuesFrom ConfigMaps, then spec.values).
     This checks the values against the chart's own schema and templates;
     the rendered manifests are then validated with kubeconform.
  4. Check every values key against the chart's values.schema.json. Many
     charts' schemas list every key but still accept unknown ones, so a typo
     or a key removed in a new chart version would otherwise be ignored.

Runs as a pre-commit hook (which provides PyYAML) and from `make validate`.
Needs kustomize, helm and kubeconform on PATH. Charts are cached under
$XDG_CACHE_HOME (default ~/.cache)/poc-multicloud-postgres/charts.
"""

from __future__ import annotations

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
# CRD schemas for Flux, cert-manager and others, pinned to a commit.
CRD_SCHEMAS = (
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


def kubeconform(manifests: str, label: str, ignore_missing: bool = False) -> None:
    cmd = [
        "kubeconform", "-strict", "-summary",
        "-kubernetes-version", KUBERNETES_VERSION,
        "-schema-location", "default",
        "-schema-location", CRD_SCHEMAS,
        # No JSON schema exists for CRD objects themselves; the only CRDs here
        # are vendored from releases (Flux, chart-bundled), not written by us.
        "-skip", "CustomResourceDefinition",
    ]
    if ignore_missing:
        cmd.append("-ignore-missing-schemas")
    out = run(cmd, stdin=manifests)
    print(f"  {label}: {out.strip().splitlines()[-1]}")


def read_env(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def substitute(text: str, env: dict[str, str], where: str) -> str:
    used = set()
    for match in VAR.finditer(text):
        name = match.group(1)
        if not PLAIN_VAR.match(name):
            raise Failure(f"{where}: only plain ${{VAR}} substitutions are supported, found ${{{name}}}")
        used.add(name)
    missing = sorted(used - env.keys())
    unused = sorted(env.keys() - used)
    if missing:
        raise Failure(f"{where}: uses variables not listed in cluster-vars.example.env: {', '.join(missing)}")
    if unused:
        raise Failure(f"{where}: cluster-vars.example.env lists variables nothing uses: {', '.join(unused)}")
    return VAR.sub(lambda m: env[m.group(1)], text)


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


def render_helm_releases(docs: list[dict], cloud: str) -> None:
    repos = {
        (d["metadata"]["namespace"], d["metadata"]["name"]): d
        for d in docs if d.get("kind") == "HelmRepository"
    }
    configmaps = {
        (d["metadata"]["namespace"], d["metadata"]["name"]): d
        for d in docs if d.get("kind") == "ConfigMap"
    }
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
        if schema is not None:
            unknown = unknown_keys(values, schema, schema)
            if unknown:
                raise Failure(
                    f"{cloud}: HelmRelease {ns}/{name} sets keys that {spec['chart']} {spec['version']} "
                    f"doesn't define: {', '.join(unknown)}"
                )
        with tempfile.NamedTemporaryFile("w", suffix=".yaml") as f:
            yaml.safe_dump(values, f)
            f.flush()
            rendered = run([
                "helm", "template", hr["spec"].get("releaseName", name), str(chart),
                "--namespace", ns, "--kube-version", KUBERNETES_VERSION, "-f", f.name,
            ])
        # Charts may render custom resources (e.g. cert-manager Certificates)
        # whose schemas aren't in the catalog; those are skipped, the rest is strict.
        kubeconform(rendered, f"helm template {ns}/{name} ({spec['chart']} {spec['version']})", ignore_missing=True)


def check_bootstrap_matches(cloud_docs: dict[str, list[dict]]) -> None:
    """bootstrap.sh installs Cilium (and CoreDNS on EKS) at the versions Flux manages."""
    script = (ROOT / "k8s" / "bootstrap.sh").read_text()
    pins = {"cilium": "CILIUM_VERSION", "coredns": "COREDNS_VERSION"}
    for release, variable in pins.items():
        match = re.search(rf'^{variable}="([^"]+)"', script, re.MULTILINE)
        if not match:
            raise Failure(f"k8s/bootstrap.sh: {variable} not found")
        for cloud, docs in cloud_docs.items():
            hr = next((d for d in docs if d.get("kind") == "HelmRelease" and d["metadata"]["name"] == release), None)
            if hr is None:
                continue  # e.g. CoreDNS is only managed on EKS
            pinned = hr["spec"]["chart"]["spec"]["version"]
            if pinned != match.group(1):
                raise Failure(
                    f"k8s/bootstrap.sh installs {release} {match.group(1)} but the {cloud} HelmRelease pins "
                    f"{pinned}; Flux would immediately change it"
                )
        print(f"bootstrap.sh {release} version matches the HelmReleases ({match.group(1)})")


def check_flux_version() -> None:
    """The committed Flux install manifests match the flux CLI pinned in .tool-versions."""
    pinned = read_env_like(ROOT / ".tool-versions").get("flux")
    header = re.search(r"^# Flux Version: v(\S+)", (ROOT / "k8s" / "flux" / "gotk-components.yaml").read_text(), re.MULTILINE)
    if not pinned or not header:
        raise Failure("can't read the Flux version from .tool-versions or k8s/flux/gotk-components.yaml")
    if header.group(1) != pinned:
        raise Failure(f"k8s/flux/gotk-components.yaml is Flux {header.group(1)} but .tool-versions pins {pinned}; run make flux-manifests")
    print(f"k8s/flux/gotk-components.yaml matches .tool-versions (Flux {pinned})")

    # The digest overrides must be for exactly the images and tags upstream
    # ships, so an upgrade can't keep running old images under new manifests.
    upstream = dict(
        m.groups() for m in re.finditer(r"image: (\S+):(\S+)", (ROOT / "k8s" / "flux" / "gotk-components.yaml").read_text())
    )
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


def read_env_like(path: Path) -> dict[str, str]:
    """Read `name version` lines (.tool-versions)."""
    pairs = (line.split() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#"))
    return {p[0]: p[1] for p in pairs if len(p) == 2}


def main() -> int:
    try:
        check_flux_version()
        cloud_docs = {}
        for cloud in CLOUDS:
            print(f"== {cloud}")
            kubeconform(run(["kustomize", "build", str(ROOT / "k8s" / "clusters" / cloud)]), f"clusters/{cloud}")

            env = read_env(ROOT / "k8s" / "clusters" / cloud / "cluster-vars.example.env")
            platform = run(["kustomize", "build", str(ROOT / "k8s" / "platform" / cloud)])
            platform = substitute(platform, env, f"platform/{cloud}")
            kubeconform(platform, f"platform/{cloud}")

            docs = [d for d in yaml.safe_load_all(platform) if d]
            cloud_docs[cloud] = docs
            render_helm_releases(docs, cloud)
        check_bootstrap_matches(cloud_docs)
    except Failure as e:
        print(f"k8s validation failed:\n{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
