# Rehearse a production rollback and restore the current build

Allow 20–40 minutes in a quiet window. Users may notice interruptions while pods restart. This exercise changes application images and Helm-managed configuration. It does not rewind MongoDB or S3. Keep Jenkins promotions paused and avoid uploads during the drill. Confirm the older application can read the current database schema and its five images are still in ECR.

## 1. Identify the two releases (read only)

In one Bash terminal on your Mac, from the repository root:

```bash
export AWS_PROFILE=streamingapp
prodhelm() { helm "$@" --kube-context streamingapp-capstone-prod -n streaming-app-prod; }
prodk() { kubectl --context streamingapp-capstone-prod -n streaming-app-prod "$@"; }
prodhelm history streamingapp
```

On 16 November the previous installation was revision 1 (build 22), and the deployed release was revision 2 (build 23). Jenkins build numbers and Helm revision numbers are separate. If another promotion has happened, stop and select the revisions for that release instead.

```bash
PREVIOUS=1
BASELINE=2
release_images() {
  prodhelm get values streamingapp --revision "$1" -o json | python3 -c '
import json, sys
v = json.load(sys.stdin)
for name in ["admin", "auth", "chat", "frontend", "streaming"]:
    service = v["frontend"] if name == "frontend" else v["services"][name]
    tag = service["tag"] if name == "frontend" else v["image"]["tag"]
    print(name, tag, service["digest"])'
}
release_images "$PREVIOUS"
release_images "$BASELINE"
```

Expect five rows for each build: 96a8a19cf9f4-22 and cc27dd7fa32b-23. Save the original revision numbers for recovery. To compare the live workload with either revision, define this check:

```bash
check_release() {
  local expected observed name tag digest image
  expected=$(release_images "$1") || return 1
  while read -r name tag digest; do
    prodk rollout status "deployment/$name" --timeout=3m || return 1
    image=$(prodk get deployment "$name" -o jsonpath='{.spec.template.spec.containers[0].image}') || return 1
    [[ "$image" == *"/streamingapp-capstone-$name:$tag@$digest" ]] || { echo "Unexpected image: $image"; return 1; }
    echo "$name ready: $tag@$digest"
  done <<< "$expected"
  curl -fsS --max-time 20 https://prod.sairamraavi.com/api/streaming/videos/featured |
    python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin),(dict,list)); print("Production catalogue returned JSON")'
}
check_release "$BASELINE"
```

Proceed only if the current release passes. Sign in and play a known video to establish the baseline.

## 2. Roll back to the previous build (live change)

```bash
prodhelm rollback streamingapp "$PREVIOUS" --wait --timeout 10m && check_release "$PREVIOUS"
```

Play the same video again. Helm creates a new history entry for this rollback. If the command times out or a check fails, inspect `prodhelm history streamingapp` and `prodk get deployments,pods`. Resolve any pending Helm operation before starting another. Prioritize restoring the baseline if the older release cannot serve traffic.

## 3. Restore the original build (live change)

```bash
prodhelm rollback streamingapp "$BASELINE" --wait --timeout 10m && check_release "$BASELINE"
```

Check playback once more and run `prodhelm history streamingapp`. The latest entry should be deployed, with all five workloads back on build 23. Resume Jenkins promotions. Save one screenshot showing the final history and verified build 23 output as Docs/evidence/prod-05-rollback-and-recovery.png. Keep it out of the submission until the drill succeeds.
