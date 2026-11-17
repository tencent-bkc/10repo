#!/usr/bin/env bash
set -euo pipefail

# GitHub public mirror acceptance reference for Checkout implementers.
# Secrets are supplied through environment variables; never enable `set -x`.

TARGET_URL="${TARGET_URL:-https://dev.bkcode.woa.com}"
ROOT_REPO="${ROOT_REPO:-tencent-bkc/10repo}"
SOURCE_URL="https://github.com/${ROOT_REPO}.git"
SCENARIO="${1:?scenario is required}"
POLL_MINUTES="${POLL_MINUTES:-20}"
REQUEST_CONCURRENCY="${REQUEST_CONCURRENCY:-20}"
ROUNDS="${ROUNDS:-3}"
BUILD_UID="$(printf '%s' "${BUILD_UID:-local}" | tr -cs 'A-Za-z0-9-' '-' | tail -c 41)"
WORK="$(mktemp -d)"
KNOWN_REPOS=$'tencent-bkc/10repo\ntencent-bkc/10repo-sub-child\ntencent-bkc/10repo-sub-leaf'

fail() { echo "ERROR: $*" >&2; exit 1; }
pass() { echo "RESULT $1=PASS elapsed_seconds=$(( $(date +%s) - $2 ))"; }
require() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }
urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
json_get() {
  python3 -c '
import json,sys
data=json.load(sys.stdin)
for key in sys.argv[1].split("."):
    data=(data or {}).get(key)
if isinstance(data,(dict,list)): print(json.dumps(data,separators=(",",":")))
elif data is not None: print(str(data).lower() if isinstance(data,bool) else data)
' "$1"
}

require git
require curl
require python3
[ "$TARGET_URL" = "https://dev.bkcode.woa.com" ] || fail "tests are restricted to dev.bkcode.woa.com"
[ -n "${BK_CODE_TOKEN:-}" ] || fail "BK_CODE_TOKEN is empty"
[ -n "${GITHUB_TOKEN:-}" ] || fail "GITHUB_TOKEN is empty"

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1
export HOME="$WORK/home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_LFS_SKIP_SMUDGE=1
mkdir -p "$HOME"

ASKPASS="$WORK/askpass.sh"
cat >"$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
EOF
chmod 700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS"

HTTP_STATUS=
HTTP_BODY=
api() {
  local method="$1" path="$2" data="${3:-}" body="$WORK/api-body"
  local args=(-sS -o "$body" -w '%{http_code}' -X "$method"
    -H "X-BKCODE-PRIVATE-TOKEN: $BK_CODE_TOKEN" -H 'Accept: application/json')
  if [ -n "$data" ]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  HTTP_STATUS="$(curl "${args[@]}" "$TARGET_URL$path")"
  HTTP_BODY="$(cat "$body")"
}

repo_detail() { api GET "/api/v1/repos/$(urlencode "$1")"; }
group_detail() { api GET "/api/v1/groups/$(urlencode "${1:-tencent-bkc}")"; }
mirror_detail() { api GET "/api/v1/repos/$(urlencode "$1")/mirror/pull"; }
mirror_url() { printf '%s/%s.git' "$TARGET_URL" "$1"; }
source_url() { printf 'https://github.com/%s.git' "$1"; }

decision() {
  local repo="${1:-$ROOT_REPO}" headers="$WORK/headers-$(echo "$repo" | tr / -)"
  DECISION_STATUS="$(curl -sS -o /dev/null -D "$headers" -w '%{http_code}' --max-redirs 0 \
    "$(mirror_url "$repo")/info/refs?service=git-upload-pack")"
  DECISION_LOCATION="$(awk 'BEGIN{IGNORECASE=1}/^location:/{sub(/\r$/,"");sub(/^[^:]+:[[:space:]]*/,"");print;exit}' "$headers")"
}

trigger() {
  decision "${1:-$ROOT_REPO}"
  case "$DECISION_STATUS" in 200|307|401) ;; *) fail "unexpected decision HTTP $DECISION_STATUS for ${1:-$ROOT_REPO}" ;; esac
}

refs() { git ls-remote "$1" "${2:-refs/heads/*}"; }

wait_ready() {
  local repo="${1:-$ROOT_REPO}" timeout="${2:-$((POLL_MINUTES*60))}" end=$(( $(date +%s)+timeout ))
  trigger "$repo"
  while [ "$(date +%s)" -lt "$end" ]; do
    repo_detail "$repo"
    local repo_status="$HTTP_STATUS"
    if [ "$repo_status" = 200 ]; then
      mirror_detail "$repo"
      if [ "$HTTP_STATUS" = 200 ] && [ "$(printf '%s' "$HTTP_BODY" | json_get data.updateStatus)" = FINISHED ]; then
        decision "$repo"
        if [ "$DECISION_STATUS" = 200 ] || [ "$DECISION_STATUS" = 401 ]; then
          diff -u <(refs "$(source_url "$repo")" | sort) <(refs "$(mirror_url "$repo")" | sort) >/dev/null &&
            { echo "READY $repo"; return; }
        fi
      fi
    fi
    sleep 10
  done
  fail "mirror did not become ready: $repo"
}

wait_ref() {
  local ref="$1" expected="$2" end=$(( $(date +%s)+POLL_MINUTES*60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    trigger "$ROOT_REPO"
    sleep 5
    [ "$(refs "$(mirror_url "$ROOT_REPO")" "$ref" | awk 'NR==1{print $1}')" = "$expected" ] &&
      { wait_ready "$ROOT_REPO"; return; }
  done
  fail "mirror ref did not converge: $ref"
}

wait_ref_absent() {
  local ref="$1" end=$(( $(date +%s)+POLL_MINUTES*60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    trigger "$ROOT_REPO"
    sleep 5
    [ -z "$(refs "$(mirror_url "$ROOT_REPO")" "$ref")" ] && { wait_ready "$ROOT_REPO"; return; }
  done
  fail "mirror retained deleted ref: $ref"
}

delete_repo() {
  local repo="$1"
  repo_detail "$repo"
  [ "$HTTP_STATUS" = 404 ] && return
  [ "$HTTP_STATUS" = 200 ] || fail "query repository failed: $repo HTTP $HTTP_STATUS"
  [ "$(printf '%s' "$HTTP_BODY" | json_get data.path)" = "$repo" ] || fail "refusing to delete unexpected repository"
  api DELETE "/api/v1/repos/$(urlencode "$repo")"
  case "$HTTP_STATUS" in 200|202|204) ;; *) fail "delete repository failed: $repo HTTP $HTTP_STATUS" ;; esac
  for _ in $(seq 1 30); do repo_detail "$repo"; [ "$HTTP_STATUS" = 404 ] && return; sleep 2; done
  fail "repository still exists: $repo"
}

safe_reset_group() {
  local paths unknown
  api GET "/api/v1/repos?page=1&pageSize=100&keyword=tencent-bkc"
  [ "$HTTP_STATUS" = 200 ] || fail "list repositories failed"
  paths="$(printf '%s' "$HTTP_BODY" | python3 -c '
import json,sys
for r in (json.load(sys.stdin).get("data") or {}).get("records",[]):
 p=str(r.get("path",""))
 if p.startswith("tencent-bkc/"): print(p)
')"
  unknown="$(comm -23 <(printf '%s\n' "$paths" | sed '/^$/d' | sort) <(printf '%s\n' "$KNOWN_REPOS" | sort))"
  [ -z "$unknown" ] || fail "group contains non-whitelisted repositories: $unknown"
  while IFS= read -r repo; do [ -n "$repo" ] && delete_repo "$repo"; done <<<"$KNOWN_REPOS"
  group_detail
  [ "$HTTP_STATUS" = 404 ] && return
  [ "$HTTP_STATUS" = 200 ] || fail "query group failed"
  api DELETE "/api/v1/groups/$(urlencode tencent-bkc)"
  case "$HTTP_STATUS" in 200|202|204) ;; *) fail "delete group failed: HTTP $HTTP_STATUS" ;; esac
}

trace_git() {
  local expected="$1" forbidden="$2" trace="$3"; shift 3
  GIT_TRACE_CURL=1 "$@" 2>"$trace" || { tail -n 60 "$trace" | sed -E 's/(authorization:).*/\1 [REDACTED]/I'; return 1; }
  grep -qi "$expected" "$trace" || fail "trace did not contain $expected"
  [ -z "$forbidden" ] || ! grep -qi "$forbidden" "$trace" || fail "trace unexpectedly contained $forbidden"
}

clone_mirror() {
  local dest="$1"; shift
  rm -rf "$dest"
  trace_git dev.bkcode.woa.com github.com "$WORK/clone.trace" git clone "$@" "$(mirror_url "$ROOT_REPO")" "$dest"
}

source_clone() {
  local dest="$1"
  rm -rf "$dest"
  git clone --filter=blob:none "$SOURCE_URL" "$dest"
  git -C "$dest" config user.name 'BK-Code Mirror Test'
  git -C "$dest" config user.email mirror-test@bkcode.invalid
}

new_branch() {
  local dir="$1" branch="$2" count="${3:-1}"
  source_clone "$dir"
  git -C "$dir" checkout -b "$branch" origin/main
  BRANCH_SHAS=()
  for i in $(seq 1 "$count"); do
    printf '%s %s %s\n' "$branch" "$i" "$(date +%s%N)" >"$dir/.mirror-$branch-$i"
    git -C "$dir" add ".mirror-$branch-$i"
    git -C "$dir" commit -m "mirror test $branch $i"
    git -C "$dir" push origin "HEAD:refs/heads/$branch"
    BRANCH_SHAS+=("$(git -C "$dir" rev-parse HEAD)")
  done
}

delete_refs() {
  local dir="$1"; shift
  for ref in "$@"; do git -C "$dir" push origin ":$ref" || true; done
}

scenario_group_lifecycle() {
  local started="$(date +%s)" group_id
  safe_reset_group
  decision
  [ "$DECISION_STATUS" = 307 ] && [[ "$DECISION_LOCATION" == https://github.com/tencent-bkc/10repo.git* ]] ||
    fail "first request did not fall back to GitHub"
  for _ in $(seq 1 5); do trigger; done
  wait_ready
  group_detail; [ "$HTTP_STATUS" = 200 ] || fail "group was not created"
  [ "$(printf '%s' "$HTTP_BODY" | json_get data.groupType)" = INTERNAL ] || fail "group is not INTERNAL"
  group_id="$(printf '%s' "$HTTP_BODY" | json_get data.id)"
  delete_repo "$ROOT_REPO"
  group_detail; [ "$(printf '%s' "$HTTP_BODY" | json_get data.id)" = "$group_id" ] || fail "group identity changed"
  wait_ready
  repo_detail "$ROOT_REPO"
  [ "$(printf '%s' "$HTTP_BODY" | json_get data.groupId)" = "$group_id" ] || fail "existing group was not reused"
  pass group-lifecycle "$started"
}

concurrent_burst() {
  local total=$((REQUEST_CONCURRENCY*ROUNDS)) dir="$WORK/concurrent"
  mkdir -p "$dir"
  for i in $(seq 1 "$total"); do
    (curl -sS -o /dev/null -w '%{http_code}' --max-redirs 0 \
      "$(mirror_url "$ROOT_REPO")/info/refs?service=git-upload-pack" >"$dir/$i") &
    while [ "$(jobs -rp | wc -l)" -ge "$REQUEST_CONCURRENCY" ]; do wait -n; done
  done
  wait
  awk '{c[$1]++}END{for(k in c)print "concurrent_http_"k"="c[k]}' "$dir"/*
  awk '$1!=200&&$1!=307&&$1!=401{bad++}END{exit bad?1:0}' "$dir"/* || fail "concurrent request failed"
}

scenario_concurrent_import_sync() {
  local started="$(date +%s)" branch="mirror-concurrent-$BUILD_UID" src="$WORK/concurrent-src"
  [ "$REQUEST_CONCURRENCY" -ge 2 ] && [ "$REQUEST_CONCURRENCY" -le 50 ] || fail "unsafe concurrency"
  [ "$ROUNDS" -ge 1 ] && [ "$ROUNDS" -le 5 ] || fail "unsafe rounds"
  safe_reset_group; concurrent_burst; wait_ready
  [ "$(printf '%s\n' "$(api GET "/api/v1/repos?page=1&pageSize=100&keyword=10repo"; printf '%s' "$HTTP_BODY")" |
    python3 -c 'import json,sys;print(sum(r.get("path")=="tencent-bkc/10repo" for r in json.load(sys.stdin)["data"]["records"]))')" = 1 ] ||
    fail "duplicate repository resources"
  new_branch "$src" "$branch"; concurrent_burst; wait_ref "refs/heads/$branch" "${BRANCH_SHAS[-1]}"
  delete_refs "$src" "refs/heads/$branch"; concurrent_burst; wait_ref_absent "refs/heads/$branch"
  pass concurrent-import-sync "$started"
}

scenario_protocol_basics() {
  local started="$(date +%s)" dest="$WORK/protocol" trace="$WORK/protocol.trace"
  wait_ready
  GIT_TRACE_PACKET=1 git -c protocol.version=2 ls-remote "$(mirror_url "$ROOT_REPO")" >"$WORK/refs" 2>"$trace"
  grep -q 'version 2' "$trace" || fail "protocol v2 was not negotiated"
  diff -u <(git ls-remote "$SOURCE_URL" | grep -E $'\t(HEAD|refs/heads/|refs/tags/)' | sort) \
    <(git ls-remote "$(mirror_url "$ROOT_REPO")" | grep -E $'\t(HEAD|refs/heads/|refs/tags/)' | sort)
  git ls-remote --symref "$(mirror_url "$ROOT_REPO")" HEAD | grep -q $'ref: refs/heads/main\tHEAD' || fail "HEAD is not main"
  clone_mirror "$dest"
  git -C "$dest" cat-file -e "$(git -C "$dest" rev-parse HEAD)^{commit}"
  pass protocol-basics "$started"
}

scenario_clone_modes() {
  local started="$(date +%s)" tag
  wait_ready
  clone_mirror "$WORK/shallow" --depth=1 --single-branch --branch main
  [ "$(git -C "$WORK/shallow" rev-parse --is-shallow-repository)" = true ] || fail "not shallow"
  git -C "$WORK/shallow" fetch --deepen=1 origin
  git -C "$WORK/shallow" fetch --unshallow origin
  clone_mirror "$WORK/no-tags" --no-tags --depth=1
  tag="$(git ls-remote --tags "$SOURCE_URL" | awk '!/\^\{\}$/{sub("refs/tags/","",$2);print $2;exit}')"
  [ -n "$tag" ] || fail "fixture has no tag"
  git -C "$WORK/no-tags" fetch origin "refs/tags/$tag:refs/tags/$tag"
  clone_mirror "$WORK/partial" --filter=blob:none --no-checkout
  [ "$(git -C "$WORK/partial" config --get remote.origin.promisor)" = true ] || fail "partial clone degraded"
  git -C "$WORK/partial" checkout main
  clone_mirror "$WORK/sparse" --filter=blob:none --no-checkout
  git -C "$WORK/sparse" sparse-checkout init --no-cone
  git -C "$WORK/sparse" sparse-checkout set README.md
  git -C "$WORK/sparse" checkout main
  [ -f "$WORK/sparse/README.md" ] && [ ! -f "$WORK/sparse/random_file.bin" ] || fail "sparse checkout failed"
  pass clone-modes "$started"
}

scenario_fetch_incremental() {
  local started="$(date +%s)" branch="mirror-fetch-$BUILD_UID" src="$WORK/fetch-src"
  wait_ready; clone_mirror "$WORK/fetch-client"
  new_branch "$src" "$branch" 2
  for sha in "${BRANCH_SHAS[@]}"; do
    wait_ref "refs/heads/$branch" "$sha"
    trace_git dev.bkcode.woa.com github.com "$WORK/fetch.trace" git -C "$WORK/fetch-client" \
      fetch origin "refs/heads/$branch:refs/remotes/origin/$branch"
    [ "$(git -C "$WORK/fetch-client" rev-parse "origin/$branch")" = "$sha" ] || fail "incremental fetch mismatch"
  done
  delete_refs "$src" "refs/heads/$branch"; wait_ref_absent "refs/heads/$branch"
  pass fetch-incremental "$started"
}

scenario_ref_mutations() {
  local started="$(date +%s)" branch="mirror-mutate-$BUILD_UID" light="light-$BUILD_UID" ann="ann-$BUILD_UID"
  local src="$WORK/mutate-src" forced
  wait_ready; new_branch "$src" "$branch"
  git -C "$src" tag "$light" "${BRANCH_SHAS[0]}"
  git -C "$src" tag -a "$ann" -m 'mirror annotated tag' "${BRANCH_SHAS[0]}"
  git -C "$src" push origin "refs/tags/$light" "refs/tags/$ann"
  wait_ref "refs/tags/$light" "$(git -C "$src" rev-parse "refs/tags/$light")"
  wait_ref "refs/tags/$ann" "$(git -C "$src" rev-parse "refs/tags/$ann")"
  git -C "$src" checkout --orphan "orphan-$BUILD_UID"
  git -C "$src" rm -rf .
  echo forced >"$src/forced-history.txt"
  git -C "$src" add forced-history.txt
  git -C "$src" commit -m 'forced history'
  forced="$(git -C "$src" rev-parse HEAD)"
  git -C "$src" push --force origin "HEAD:refs/heads/$branch"
  wait_ref "refs/heads/$branch" "$forced"
  delete_refs "$src" "refs/heads/$branch" "refs/tags/$light" "refs/tags/$ann"
  wait_ref_absent "refs/heads/$branch"; wait_ref_absent "refs/tags/$light"; wait_ref_absent "refs/tags/$ann"
  pass ref-mutations "$started"
}

checkout_once() {
  local url="$1" ref="$2" dest="$3" expected="$4" forbidden="$5"
  mkdir -p "$dest"; git -C "$dest" init; git -C "$dest" remote add origin "$url"
  trace_git "$expected" "$forbidden" "$WORK/checkout.trace" git -C "$dest" fetch --depth "${FETCH_DEPTH:-1}" origin "$ref"
  git -C "$dest" checkout --detach FETCH_HEAD
}

scenario_checkout_shell_reference() {
  local started="$(date +%s)" ref="${CHECKOUT_REF:-main}"
  wait_ready
  checkout_once "$(mirror_url "$ROOT_REPO")" "$ref" "$WORK/checkout-mirror" dev.bkcode.woa.com github.com
  checkout_once "$SOURCE_URL" "$ref" "$WORK/checkout-source" github.com dev.bkcode.woa.com
  for expr in HEAD 'HEAD^{tree}' HEAD:apisix; do
    [ "$(git -C "$WORK/checkout-mirror" rev-parse "$expr")" = "$(git -C "$WORK/checkout-source" rev-parse "$expr")" ] ||
      fail "checkout result differs: $expr"
  done
  pass checkout-shell-reference "$started"
}

scenario_push_isolation() {
  local started="$(date +%s)" branch="mirror-push-$BUILD_UID" dest="$WORK/push" sha
  wait_ready; clone_mirror "$dest"
  git -C "$dest" remote set-url --push origin "$SOURCE_URL"
  git -C "$dest" config user.name 'BK-Code Mirror Test'; git -C "$dest" config user.email mirror-test@bkcode.invalid
  git -C "$dest" checkout -b "$branch"; echo push >"$dest/$branch"; git -C "$dest" add "$branch"; git -C "$dest" commit -m push-isolation
  sha="$(git -C "$dest" rev-parse HEAD)"
  trace_git github.com dev.bkcode.woa.com "$WORK/push.trace" git -C "$dest" push origin "HEAD:refs/heads/$branch"
  wait_ref "refs/heads/$branch" "$sha"
  git -C "$dest" push "$(mirror_url "$ROOT_REPO")" "HEAD:refs/heads/rejected-$BUILD_UID" && fail "mirror accepted push" || true
  delete_refs "$dest" "refs/heads/$branch"; wait_ref_absent "refs/heads/$branch"
  pass push-isolation "$started"
}

scenario_submodule() {
  local started="$(date +%s)" dest="$WORK/submodule"
  wait_ready; wait_ready apache/apisix 2700
  git config --global "url.$(mirror_url apache/apisix).insteadOf" https://github.com/apache/apisix.git
  clone_mirror "$dest"
  trace_git dev.bkcode.woa.com github.com "$WORK/submodule.trace" git -C "$dest" submodule update --init apisix
  [ "$(git -C "$dest" rev-parse HEAD:apisix)" = "$(git -C "$dest/apisix" rev-parse HEAD)" ] || fail "apisix gitlink mismatch"
  pass submodule "$started"
}

scenario_nested_relative_submodule() {
  local started="$(date +%s)" dest="$WORK/nested"
  for repo in tencent-bkc/10repo-sub-child tencent-bkc/10repo-sub-leaf; do
    curl -fsS "https://api.github.com/repos/$repo" >/dev/null || fail "fixture missing: $repo"
    wait_ready "$repo" 2700
  done
  wait_ready apache/apisix 2700; wait_ready
  git config --global "url.$(mirror_url apache/apisix).insteadOf" https://github.com/apache/apisix.git
  clone_mirror "$dest"
  trace_git dev.bkcode.woa.com github.com "$WORK/nested.trace" git -C "$dest" submodule update --init --recursive
  [ "$(git -C "$dest" rev-parse HEAD:nested/child)" = "$(git -C "$dest/nested/child" rev-parse HEAD)" ] || fail "child mismatch"
  [ "$(git -C "$dest/nested/child" rev-parse HEAD:nested/leaf)" = "$(git -C "$dest/nested/child/nested/leaf" rev-parse HEAD)" ] || fail "leaf mismatch"
  pass nested-relative-submodule "$started"
}

lfs_verify() {
  local repo="$1"
  python3 - "$repo" <<'PY'
import hashlib,pathlib,re,subprocess,sys
repo=pathlib.Path(sys.argv[1]); checked=0
for line in subprocess.check_output(["git","-C",str(repo),"ls-files","-z","--stage"]).decode().split("\0"):
    if not line or "\t" not in line or line.startswith("160000 "): continue
    path=line.split("\t",1)[1]
    pointer=subprocess.run(["git","-C",str(repo),"show","HEAD:"+path],text=True,capture_output=True).stdout
    if not pointer.startswith("version https://git-lfs.github.com/spec/v1\n"): continue
    oid=re.search(r"(?m)^oid sha256:([0-9a-f]+)$",pointer).group(1)
    size=int(re.search(r"(?m)^size (\d+)$",pointer).group(1))
    data=(repo/path).read_bytes()
    if len(data)!=size or hashlib.sha256(data).hexdigest()!=oid: raise SystemExit("LFS mismatch: "+path)
    checked+=1
if checked<3: raise SystemExit("expected at least 3 LFS objects")
PY
}

scenario_lfs() {
  local started="$(date +%s)" dest="$WORK/lfs"
  require git-lfs; wait_ready; clone_mirror "$dest"
  git -C "$dest" lfs install --local
  trace_git dev.bkcode.woa.com github.com "$WORK/lfs.trace" git -C "$dest" lfs fetch --all
  git -C "$dest" lfs checkout; lfs_verify "$dest"
  rm -rf "$dest/.git/lfs/objects"
  trace_git dev.bkcode.woa.com github.com "$WORK/lfs-pull.trace" git -C "$dest" lfs pull
  lfs_verify "$dest"
  pass lfs "$started"
}

scenario_readonly() {
  local started="$(date +%s)" dest="$WORK/readonly" source_before mirror_before
  wait_ready; source_before="$(git ls-remote "$SOURCE_URL")"; mirror_before="$(git ls-remote "$(mirror_url "$ROOT_REPO")")"
  clone_mirror "$dest"; git -C "$dest" checkout -b "readonly-$BUILD_UID"
  git -C "$dest" push origin HEAD && fail "mirror accepted branch push" || true
  git -C "$dest" tag "readonly-$BUILD_UID"; git -C "$dest" push origin --tags && fail "mirror accepted tag push" || true
  [ "$source_before" = "$(git ls-remote "$SOURCE_URL")" ] && [ "$mirror_before" = "$(git ls-remote "$(mirror_url "$ROOT_REPO")")" ] ||
    fail "rejected push changed refs"
  pass readonly "$started"
}

scenario_path_occupied() {
  local started="$(date +%s)" group_id
  delete_repo "$ROOT_REPO"; group_detail
  if [ "$HTTP_STATUS" = 404 ]; then
    api POST /api/v1/groups '{"name":"tencent-bkc","displayName":"tencent-bkc","groupType":"INTERNAL"}'
    [ "$HTTP_STATUS" = 201 ] || fail "create group failed"
  fi
  group_id="$(printf '%s' "$HTTP_BODY" | json_get data.id)"
  api POST /api/v1/repos "{\"groupId\":$group_id,\"name\":\"10repo\",\"displayName\":\"ordinary collision\"}"
  [ "$HTTP_STATUS" = 201 ] || fail "create ordinary repository failed"
  decision; [ "$DECISION_STATUS" = 307 ] || fail "occupied path did not fall back"
  repo_detail "$ROOT_REPO"; [ "$(printf '%s' "$HTTP_BODY" | json_get data.mirror)" = false ] || fail "ordinary repo overwritten"
  mirror_detail "$ROOT_REPO"; [ "$HTTP_STATUS" = 404 ] || fail "ordinary repo gained mirror config"
  delete_repo "$ROOT_REPO"; wait_ready
  pass path-occupied "$started"
}

scenario_large_repo() {
  local started="$(date +%s)" url="${LARGE_REPO_URL:-}" repo default dest
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(\.git)?/?$ ]] || fail "invalid LARGE_REPO_URL"
  repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  default="$(curl -fsS "https://api.github.com/repos/$repo" | json_get default_branch)"
  wait_ready "$repo" "$(( ${LARGE_REPO_TIMEOUT_MINUTES:-60}*60 ))"
  for i in 1 2; do
    dest="$WORK/large-shallow-$i"; time git clone --depth=1 --single-branch --branch "$default" "$(mirror_url "$repo")" "$dest"
    du -sh "$dest" "$dest/.git"
  done
  for i in 1 2; do
    dest="$WORK/large-partial-$i"; time git clone --filter=blob:none --no-checkout "$(mirror_url "$repo")" "$dest"
    [ "$(git -C "$dest" config --get remote.origin.promisor)" = true ] || fail "partial clone degraded"
    git -C "$dest" checkout "$default"
  done
  git -C "$WORK/large-shallow-1" fetch --deepen=10 origin
  [ "${LARGE_REPO_FULL_CLONE:-false}" != true ] || git -C "$WORK/large-shallow-1" fetch --unshallow origin
  pass large-repo "$started"
}

case "$SCENARIO" in
  group-lifecycle) scenario_group_lifecycle ;;
  concurrent-import-sync) scenario_concurrent_import_sync ;;
  protocol-basics) scenario_protocol_basics ;;
  clone-modes) scenario_clone_modes ;;
  fetch-incremental) scenario_fetch_incremental ;;
  ref-mutations) scenario_ref_mutations ;;
  checkout-shell-reference) scenario_checkout_shell_reference ;;
  push-isolation) scenario_push_isolation ;;
  submodule) scenario_submodule ;;
  nested-relative-submodule) scenario_nested_relative_submodule ;;
  lfs) scenario_lfs ;;
  readonly) scenario_readonly ;;
  path-occupied) scenario_path_occupied ;;
  large-repo) scenario_large_repo ;;
  *) fail "unknown scenario: $SCENARIO" ;;
esac

rm -rf "$WORK"
