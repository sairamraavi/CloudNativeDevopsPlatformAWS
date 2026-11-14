"""Update the existing dev SES credentials and the Alertmanager receiver together."""
import base64
import getpass
import json
import subprocess
import sys


def patch(resource, kind, payload, dry_run=False):
    command = [
        "kubectl", "--context", "streamingapp-capstone-dev", "-n", "monitoring",
        "patch", *resource, "--type", kind, "--patch-file", "/dev/stdin",
        "-o", "name",
    ]
    if dry_run:
        command.append("--dry-run=server")
    subprocess.run(command, input=json.dumps(payload), text=True, check=True)


def main():
    if not sys.stdin.isatty():
        sys.exit("Run interactively in your Mac terminal.")
    username = getpass.getpass("Mumbai SES SMTP username (hidden): ").strip()
    password = getpass.getpass("Matching SES SMTP password (hidden): ").strip()
    if not username or not password:
        sys.exit("Both SMTP credentials are required.")
    data = {k: base64.b64encode(v.encode()).decode()
            for k, v in {"username": username, "password": password}.items()}
    receiver = "/spec/receivers/1"
    patch_route = [
        {"op": "test", "path": receiver + "/name", "value": "outlook-email"},
        {"op": "test", "path": receiver + "/emailConfigs/0/authPassword/name", "value": "alertmanager-ses-smtp"},
        {"op": "test", "path": receiver + "/emailConfigs/0/authPassword/key", "value": "password"},
        {"op": "replace", "path": receiver + "/emailConfigs/0/authUsername", "value": username},
    ]
    # Validate both patches against the cluster before changing either resource.
    for dry_run in (True, False):
        patch(["alertmanagerconfig", "capstone-email"], "json", patch_route, dry_run)
        patch(["secret", "alertmanager-ses-smtp"], "merge", {"data": data}, dry_run)
    print("SMTP settings updated. Check the next Alertmanager delivery attempt.")


if __name__ == "__main__":
    main()
