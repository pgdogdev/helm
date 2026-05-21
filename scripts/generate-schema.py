#!/usr/bin/env python3
"""Generate values.schema.json from Helm template .Values references.

Scans all templates for .Values.* usage, infers types from context
(pgdog.intval → integer, | quote → string, toYaml → object, etc.),
and merges manually maintained overrides (enums, descriptions, required
fields) from scripts/schema-overrides.yaml.

Usage:
    python3 scripts/generate-schema.py          # writes values.schema.json
    python3 scripts/generate-schema.py --check  # exits non-zero if schema is stale
"""

import json
import os
import re
import sys
from pathlib import Path

# Optional: PyYAML for overrides. Falls back gracefully if not installed.
try:
    import yaml
except ImportError:
    yaml = None

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATES_DIR = REPO_ROOT / "templates"
SCHEMA_PATH = REPO_ROOT / "values.schema.json"
OVERRIDES_PATH = REPO_ROOT / "scripts" / "schema-overrides.yaml"

# ---------------------------------------------------------------------------
# 1. Extract .Values references and their template context
# ---------------------------------------------------------------------------

# Matches .Values.foo.bar.baz  (captures the dotted path after .Values.)
VALUES_RE = re.compile(r"\.Values\.([a-zA-Z_][\w]*(?:\.[a-zA-Z_][\w]*)*)")

# Context patterns that hint at a type.  Order matters: first match wins.
# NOTE: boolean is never auto-inferred — it must come from overrides.
# Template `if .Values.X` is a truthiness check, not a type indicator.
CONTEXT_PATTERNS = [
    # pgdog.intval → integer (accepts int or underscore-separated string)
    (re.compile(r'include\s+"pgdog\.intval".*\.Values\.{path}\b'), "integer"),
    (re.compile(r'\.Values\.{path}\b.*\|\s*int\b'), "integer"),
    # | toYaml / with .Values.X → object
    (re.compile(r"\.Values\.{path}\b\s*\|\s*toYaml"), "object"),
    (re.compile(r"toYaml\s+\.Values\.{path}\b"), "object"),
    (re.compile(r"with\s+\.Values\.{path}\b\s"), "object"),
    # | toToml → array
    (re.compile(r"\.Values\.{path}\b\s*\|\s*toToml"), "array"),
    # range .Values.X → array
    (re.compile(r"range\s+\.Values\.{path}\b"), "array"),
    # | quote → string (allow intermediate filters like `| default "foo" | quote`)
    (re.compile(r"\.Values\.{path}\b[^}]*\|\s*quote"), "string"),
]


def scan_templates():
    """Return {dotted_path: set_of_inferred_types} from all template files."""
    refs = {}  # path → set of type hints

    for tpl in TEMPLATES_DIR.rglob("*"):
        if tpl.is_dir() or tpl.suffix not in (".yaml", ".yml", ".tpl", ".txt"):
            continue
        text = tpl.read_text()

        for m in VALUES_RE.finditer(text):
            path = m.group(1)
            if path not in refs:
                refs[path] = set()

            # Try each context pattern to infer type
            for pattern, typ in CONTEXT_PATTERNS:
                concrete = pattern.pattern.replace("{path}", re.escape(path))
                if re.search(concrete, text):
                    refs[path].add(typ)
                    break

    return refs


# ---------------------------------------------------------------------------
# 2. Build a nested property tree
# ---------------------------------------------------------------------------


def build_tree(refs):
    """Convert flat dotted paths into a nested dict.

    Each leaf is {"_types": set(), "_is_leaf": True}.
    Intermediate nodes are plain dicts.
    """
    tree = {}
    for dotted, types in refs.items():
        parts = dotted.split(".")
        node = tree
        for i, part in enumerate(parts):
            if part not in node:
                node[part] = {}
            node = node[part]
            if i == len(parts) - 1:
                node["_types"] = types
                node["_is_leaf"] = True
    return tree


# ---------------------------------------------------------------------------
# 3. Resolve types
# ---------------------------------------------------------------------------

# Fields whose template usage looks boolean (if .Values.X) but are actually
# strings/numbers are handled via overrides.  This function just picks the
# best single type from the inferred set.

TYPE_PRIORITY = {"integer": 0, "string": 1, "array": 2, "object": 3, "boolean": 4}


def pick_type(types):
    """Pick the most specific type from a set of inferred types."""
    if not types:
        return "string"  # safe default for unknown
    # If we have both object and string (e.g. toYaml + quote in different
    # contexts), prefer object since quote may be from a sub-field.
    if "object" in types:
        return "object"
    if "array" in types:
        return "array"
    if "integer" in types:
        return "integer"
    # Return the highest-priority (most specific) type
    return min(types, key=lambda t: TYPE_PRIORITY.get(t, 99))


# ---------------------------------------------------------------------------
# 4. Load overrides
# ---------------------------------------------------------------------------


def load_overrides():
    """Load schema-overrides.yaml if it exists and PyYAML is available."""
    if yaml is None:
        print("WARNING: PyYAML not installed; skipping overrides", file=sys.stderr)
        return {}
    if not OVERRIDES_PATH.exists():
        return {}
    with open(OVERRIDES_PATH) as f:
        data = yaml.safe_load(f) or {}
    return data


# ---------------------------------------------------------------------------
# 5. Generate JSON Schema
# ---------------------------------------------------------------------------

# Shared $defs that are referenced via $ref
DEFS = {
    "resources": {
        "type": "object",
        "description": "Kubernetes resource requests and limits",
        "additionalProperties": False,
        "properties": {
            "requests": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "cpu": {"type": ["string", "number"]},
                    "memory": {"type": "string"},
                },
            },
            "limits": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "cpu": {"type": ["string", "number"]},
                    "memory": {"type": "string"},
                },
            },
        },
    },
    "awsLb": {
        "type": "object",
        "description": "AWS Load Balancer Controller configuration",
        "additionalProperties": False,
        "properties": {
            "enabled": {"type": "boolean", "description": "Enable AWS LB annotations"},
            "scheme": {
                "type": "string",
                "description": "Load balancer scheme",
                "enum": ["internet-facing", "internal"],
            },
        },
    },
}

# Properties that should use a $ref instead of being auto-generated
REF_MAP = {
    "resources": "#/$defs/resources",
    "prometheusResources": "#/$defs/resources",
    "gateway.resources": "#/$defs/resources",
    "prometheusCollector.resources": "#/$defs/resources",
    "service.aws": "#/$defs/awsLb",
    "prometheusCollector.service.aws": "#/$defs/awsLb",
}


def apply_overrides(prop, override):
    """Merge override keys into a property dict."""
    for key in ("description", "enum", "minimum", "maximum", "pattern",
                "minItems", "maxItems"):
        if key in override:
            prop[key] = override[key]
    if "type" in override:
        prop["type"] = override["type"]
    if "required" in override:
        prop["required"] = override["required"]
    if "items" in override:
        prop["items"] = override["items"]


def tree_to_schema(tree, overrides, path_prefix=""):
    """Recursively convert property tree to JSON Schema properties dict."""
    properties = {}

    for key, node in sorted(tree.items()):
        if key.startswith("_"):
            continue

        full_path = f"{path_prefix}.{key}" if path_prefix else key
        override = overrides.get(full_path, {})

        # Check if this should be a $ref
        ref_path = REF_MAP.get(full_path)
        if ref_path:
            prop = {"$ref": ref_path}
            if "description" in override:
                prop["description"] = override["description"]
            properties[key] = prop
            continue

        is_leaf = node.get("_is_leaf", False)
        types = node.get("_types", set())

        # Filter out internal keys to find children
        children = {k: v for k, v in node.items()
                    if not k.startswith("_") and isinstance(v, dict)}

        if children and not is_leaf:
            # Pure object node
            child_props = tree_to_schema(children, overrides, full_path)
            prop = {
                "type": "object",
                "additionalProperties": False,
                "properties": child_props,
            }
        elif children and is_leaf:
            # Node that is both used directly AND has children
            # This means the templates access both .Values.X and .Values.X.foo
            # Treat as object with children
            child_props = tree_to_schema(children, overrides, full_path)
            prop = {
                "type": "object",
                "additionalProperties": False,
                "properties": child_props,
            }
        else:
            # Leaf node
            resolved = pick_type(types)
            prop = {"type": resolved}

            if resolved == "integer":
                prop["minimum"] = 0
            if resolved == "array":
                prop["items"] = {"type": "object"}

        apply_overrides(prop, override)
        properties[key] = prop

    return properties


def generate():
    print("Scanning templates...", file=sys.stderr)
    refs = scan_templates()
    print(f"  Found {len(refs)} .Values.* references", file=sys.stderr)

    tree = build_tree(refs)
    overrides = load_overrides()

    properties = tree_to_schema(tree, overrides)

    schema = {
        "$schema": "https://json-schema.org/draft-07/schema#",
        "title": "PgDog Helm Chart Values",
        "description": (
            "Schema for validating PgDog Helm chart values. "
            "All object levels use additionalProperties: false to catch typos. "
            "Generated by scripts/generate-schema.py — do not edit by hand."
        ),
        "type": "object",
        "additionalProperties": False,
        "properties": properties,
        "$defs": DEFS,
    }

    return schema


def main():
    check_mode = "--check" in sys.argv

    schema = generate()
    new_content = json.dumps(schema, indent=2, ensure_ascii=False) + "\n"

    if check_mode:
        if SCHEMA_PATH.exists():
            existing = SCHEMA_PATH.read_text()
            if existing == new_content:
                print("values.schema.json is up to date.", file=sys.stderr)
                sys.exit(0)
            else:
                print(
                    "values.schema.json is STALE. Run: python3 scripts/generate-schema.py",
                    file=sys.stderr,
                )
                sys.exit(1)
        else:
            print("values.schema.json does not exist.", file=sys.stderr)
            sys.exit(1)

    SCHEMA_PATH.write_text(new_content)
    print(f"Wrote {SCHEMA_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()
