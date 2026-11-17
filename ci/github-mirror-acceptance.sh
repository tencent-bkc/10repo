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
SCRIPT_STARTED="$(date +%s)"
CURRENT_STEP="初始化"

log() { printf '%s INFO [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$*"; }
step() {
  CURRENT_STEP="$*"
  printf '\n========== [%s] %s ==========\n' "$SCENARIO" "$CURRENT_STEP"
}
fail() {
  printf '%s ERROR [%s] step="%s" %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$CURRENT_STEP" "$*" >&2
  exit 1
}
pass() {
  log "场景通过: name=$1 elapsed_seconds=$(( $(date +%s) - $2 ))"
  printf 'RESULT %s=PASS elapsed_seconds=%s\n' "$1" "$(( $(date +%s) - $2 ))"
}
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

cleanup() {
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    log "验收结束: status=PASS elapsed_seconds=$(( $(date +%s) - SCRIPT_STARTED ))"
  else
    printf '%s ERROR [%s] 验收结束: status=FAIL step="%s" exit_code=%s elapsed_seconds=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$CURRENT_STEP" "$exit_code" \
      "$(( $(date +%s) - SCRIPT_STARTED ))" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

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
  local repo headers
  repo="${1:-$ROOT_REPO}"
  headers="$WORK/headers-$(echo "$repo" | tr / -)"
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
  local repo="${1:-$ROOT_REPO}"
  local timeout="${2:-$((POLL_MINUTES*60))}"
  local end=$(( $(date +%s) + timeout ))
  local attempt=0 repo_status mirror_status update_status decision_status summary last_summary=""
  log "等待镜像可用: repo=$repo timeout_seconds=$timeout"
  trigger "$repo"
  while [ "$(date +%s)" -lt "$end" ]; do
    attempt=$((attempt+1))
    repo_detail "$repo"
    repo_status="$HTTP_STATUS"
    mirror_status="not-checked"
    update_status="unknown"
    decision_status="not-checked"
    if [ "$repo_status" = 200 ]; then
      mirror_detail "$repo"
      mirror_status="$HTTP_STATUS"
      if [ "$mirror_status" = 200 ]; then
        update_status="$(printf '%s' "$HTTP_BODY" | json_get data.updateStatus)"
      fi
      if [ "$mirror_status" = 200 ] && [ "$update_status" = FINISHED ]; then
        decision "$repo"
        decision_status="$DECISION_STATUS"
        if [ "$DECISION_STATUS" = 200 ] || [ "$DECISION_STATUS" = 401 ]; then
          if diff -u <(refs "$(source_url "$repo")" | sort) <(refs "$(mirror_url "$repo")" | sort) >/dev/null; then
            log "镜像已就绪: repo=$repo attempt=$attempt route_http=$DECISION_STATUS refs=matched"
            echo "READY $repo"
            return
          fi
          decision_status="$DECISION_STATUS/refs-mismatch"
        fi
      fi
    fi
    summary="repo_http=$repo_status mirror_http=$mirror_status update=$update_status route=$decision_status"
    if [ "$summary" != "$last_summary" ] || [ $((attempt%6)) -eq 0 ]; then
      log "镜像尚未就绪: repo=$repo attempt=$attempt $summary"
      last_summary="$summary"
    fi
    sleep 10
  done
  fail "mirror did not become ready: $repo"
}

wait_ref() {
  local ref="$1" expected="$2" end=$(( $(date +%s)+POLL_MINUTES*60 )) attempt=0 current=""
  log "等待引用同步: repo=$ROOT_REPO ref=$ref expected=$expected"
  while [ "$(date +%s)" -lt "$end" ]; do
    attempt=$((attempt+1))
    trigger "$ROOT_REPO"
    sleep 5
    if ! current="$(refs "$(mirror_url "$ROOT_REPO")" "$ref" | awk 'NR==1{print $1}')"; then
      log "查询镜像引用失败，将继续重试: ref=$ref attempt=$attempt"
      continue
    fi
    if [ "$current" = "$expected" ]; then
      log "引用已同步: ref=$ref sha=$current attempt=$attempt"
      wait_ready "$ROOT_REPO"
      return
    fi
    if [ "$attempt" -eq 1 ] || [ $((attempt%6)) -eq 0 ]; then
      log "引用尚未同步: ref=$ref expected=$expected current=${current:-missing} attempt=$attempt"
    fi
  done
  fail "mirror ref did not converge: $ref"
}

wait_ref_absent() {
  local ref="$1" end=$(( $(date +%s)+POLL_MINUTES*60 )) attempt=0 current=""
  log "等待引用删除同步: repo=$ROOT_REPO ref=$ref"
  while [ "$(date +%s)" -lt "$end" ]; do
    attempt=$((attempt+1))
    trigger "$ROOT_REPO"
    sleep 5
    if ! current="$(refs "$(mirror_url "$ROOT_REPO")" "$ref")"; then
      log "查询镜像引用失败，将继续重试: ref=$ref attempt=$attempt"
      continue
    fi
    if [ -z "$current" ]; then
      log "引用已删除: ref=$ref attempt=$attempt"
      wait_ready "$ROOT_REPO"
      return
    fi
    if [ "$attempt" -eq 1 ] || [ $((attempt%6)) -eq 0 ]; then
      log "引用仍存在: ref=$ref attempt=$attempt"
    fi
  done
  fail "mirror retained deleted ref: $ref"
}

delete_repo() {
  local repo="$1" attempt
  log "删除测试仓库: repo=$repo"
  repo_detail "$repo"
  if [ "$HTTP_STATUS" = 404 ]; then
    log "测试仓库不存在，无需删除: repo=$repo"
    return
  fi
  [ "$HTTP_STATUS" = 200 ] || fail "query repository failed: $repo HTTP $HTTP_STATUS"
  [ "$(printf '%s' "$HTTP_BODY" | json_get data.path)" = "$repo" ] || fail "refusing to delete unexpected repository"
  api DELETE "/api/v1/repos/$(urlencode "$repo")"
  case "$HTTP_STATUS" in 200|202|204) ;; *) fail "delete repository failed: $repo HTTP $HTTP_STATUS" ;; esac
  for attempt in $(seq 1 30); do
    repo_detail "$repo"
    if [ "$HTTP_STATUS" = 404 ]; then
      log "测试仓库已删除: repo=$repo attempt=$attempt"
      return
    fi
    sleep 2
  done
  fail "repository still exists: $repo"
}

safe_reset_group() {
  local paths unknown
  log "重置测试仓库组: group=tencent-bkc"
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
  log "测试仓库组已重置: group=tencent-bkc"
}

trace_excerpt() {
  local trace="$1"
  log "Git 网络跟踪摘要（Authorization/Cookie 已脱敏）:"
  sed -E \
    -e 's/(authorization:).*/\1 [REDACTED]/I' \
    -e 's/(proxy-authorization:).*/\1 [REDACTED]/I' \
    -e 's/(cookie:).*/\1 [REDACTED]/I' \
    "$trace" |
    grep -Ei 'github\.com|dev\.bkcode\.woa\.com|Recv header: (HTTP/|location:)|Send header: (GET|POST)|Trying |Connected to |Issue another request|redirect' |
    tail -n 80 || true
}

trace_git() {
  local expected="$1" forbidden="$2" trace="$3"; shift 3
  log "执行 Git 命令: $*"
  if ! GIT_TRACE_CURL=1 "$@" 2>"$trace"; then
    log "Git 命令失败，输出网络跟踪"
    trace_excerpt "$trace"
    tail -n 60 "$trace" | sed -E \
      -e 's/(authorization:).*/\1 [REDACTED]/I' \
      -e 's/(proxy-authorization:).*/\1 [REDACTED]/I' \
      -e 's/(cookie:).*/\1 [REDACTED]/I'
    return 1
  fi
  if ! grep -qi "$expected" "$trace"; then
    trace_excerpt "$trace"
    fail "trace did not contain $expected"
  fi
  if [ -n "$forbidden" ] && grep -qi "$forbidden" "$trace"; then
    trace_excerpt "$trace"
    fail "trace unexpectedly contained $forbidden"
  fi
  log "Git 路由检查通过: expected=$expected forbidden=${forbidden:-none}"
}

clone_mirror() {
  local dest="$1"; shift
  log "克隆镜像仓库: repo=$ROOT_REPO dest=$dest options=${*:-none}"
  rm -rf "$dest"
  trace_git dev.bkcode.woa.com github.com "$WORK/clone.trace" git clone "$@" "$(mirror_url "$ROOT_REPO")" "$dest"
  log "镜像仓库克隆完成: head=$(git -C "$dest" rev-parse HEAD)"
}

source_clone() {
  local dest="$1"
  log "克隆 GitHub 源仓库用于制造测试变更: repo=$ROOT_REPO dest=$dest"
  rm -rf "$dest"
  git clone --filter=blob:none "$SOURCE_URL" "$dest"
  git -C "$dest" config user.name 'BK-Code Mirror Test'
  git -C "$dest" config user.email mirror-test@bkcode.invalid
}

push_test_commit() {
  local dir="$1" branch="$2" index="$3" sha
  printf '%s %s %s\n' "$branch" "$index" "$(date +%s%N)" >"$dir/.mirror-$branch-$index"
  git -C "$dir" add ".mirror-$branch-$index"
  git -C "$dir" commit -m "mirror test $branch $index"
  git -C "$dir" push origin "HEAD:refs/heads/$branch"
  sha="$(git -C "$dir" rev-parse HEAD)"
  BRANCH_SHAS+=("$sha")
  log "测试提交已推送: branch=$branch index=$index sha=$sha"
}

new_branch() {
  local dir="$1" branch="$2" count="${3:-1}"
  log "创建源仓库测试分支: branch=$branch commits=$count"
  source_clone "$dir"
  git -C "$dir" checkout -b "$branch" origin/main
  BRANCH_SHAS=()
  for i in $(seq 1 "$count"); do
    push_test_commit "$dir" "$branch" "$i"
  done
}

delete_refs() {
  local dir="$1"; shift
  for ref in "$@"; do
    log "删除源仓库引用: ref=$ref"
    git -C "$dir" push origin ":$ref" || true
  done
}

scenario_group_lifecycle() {
  local started="$(date +%s)" group_id
  step "1/5 清理既有测试仓库和仓库组"
  safe_reset_group
  step "2/5 验证首次访问回源 GitHub"
  decision
  log "首次路由决策: http=$DECISION_STATUS location=${DECISION_LOCATION:-none}"
  [ "$DECISION_STATUS" = 307 ] && [[ "$DECISION_LOCATION" == https://github.com/tencent-bkc/10repo.git* ]] ||
    fail "first request did not fall back to GitHub"
  step "3/5 并发触发镜像导入并等待就绪"
  for _ in $(seq 1 5); do trigger; done
  wait_ready
  step "4/5 验证仓库组类型和身份稳定性"
  group_detail; [ "$HTTP_STATUS" = 200 ] || fail "group was not created"
  [ "$(printf '%s' "$HTTP_BODY" | json_get data.groupType)" = INTERNAL ] || fail "group is not INTERNAL"
  group_id="$(printf '%s' "$HTTP_BODY" | json_get data.id)"
  delete_repo "$ROOT_REPO"
  group_detail; [ "$(printf '%s' "$HTTP_BODY" | json_get data.id)" = "$group_id" ] || fail "group identity changed"
  step "5/5 重新导入仓库并验证复用原仓库组"
  wait_ready
  repo_detail "$ROOT_REPO"
  [ "$(printf '%s' "$HTTP_BODY" | json_get data.groupId)" = "$group_id" ] || fail "existing group was not reused"
  pass group-lifecycle "$started"
}

concurrent_burst() {
  local total=$((REQUEST_CONCURRENCY*ROUNDS)) dir="$WORK/concurrent"
  log "发起并发访问: requests=$total concurrency=$REQUEST_CONCURRENCY rounds=$ROUNDS"
  mkdir -p "$dir"
  for i in $(seq 1 "$total"); do
    (curl -sS -o /dev/null -w '%{http_code}' --max-redirs 0 \
      "$(mirror_url "$ROOT_REPO")/info/refs?service=git-upload-pack" >"$dir/$i") &
    while [ "$(jobs -rp | wc -l)" -ge "$REQUEST_CONCURRENCY" ]; do wait -n; done
  done
  wait
  awk '{c[$1]++}END{for(k in c)print "concurrent_http_"k"="c[k]}' "$dir"/* | sort
  awk '$1!=200&&$1!=307&&$1!=401{bad++}END{exit bad?1:0}' "$dir"/* || fail "concurrent request failed"
  log "并发访问完成: requests=$total"
}

scenario_concurrent_import_sync() {
  local started="$(date +%s)" branch="mirror-concurrent-$BUILD_UID" src="$WORK/concurrent-src"
  step "1/5 校验并发参数并重置测试仓库组"
  [ "$REQUEST_CONCURRENCY" -ge 2 ] && [ "$REQUEST_CONCURRENCY" -le 50 ] || fail "unsafe concurrency"
  [ "$ROUNDS" -ge 1 ] && [ "$ROUNDS" -le 5 ] || fail "unsafe rounds"
  safe_reset_group
  step "2/5 并发触发首次导入并等待镜像就绪"
  concurrent_burst; wait_ready
  step "3/5 验证并发导入未产生重复仓库"
  [ "$(printf '%s\n' "$(api GET "/api/v1/repos?page=1&pageSize=100&keyword=10repo"; printf '%s' "$HTTP_BODY")" |
    python3 -c 'import json,sys;print(sum(r.get("path")=="tencent-bkc/10repo" for r in json.load(sys.stdin)["data"]["records"]))')" = 1 ] ||
    fail "duplicate repository resources"
  step "4/5 创建测试分支并验证并发增量同步"
  new_branch "$src" "$branch"; concurrent_burst; wait_ref "refs/heads/$branch" "${BRANCH_SHAS[-1]}"
  step "5/5 删除测试分支并验证并发删除同步"
  delete_refs "$src" "refs/heads/$branch"; concurrent_burst; wait_ref_absent "refs/heads/$branch"
  pass concurrent-import-sync "$started"
}

scenario_protocol_basics() {
  local started="$(date +%s)" dest="$WORK/protocol" trace="$WORK/protocol.trace"
  step "1/4 等待镜像就绪"
  wait_ready
  step "2/4 验证 Git protocol v2"
  GIT_TRACE_PACKET=1 git -c protocol.version=2 ls-remote "$(mirror_url "$ROOT_REPO")" >"$WORK/refs" 2>"$trace"
  grep -q 'version 2' "$trace" || fail "protocol v2 was not negotiated"
  log "Git protocol v2 协商成功"
  step "3/4 比对源仓库与镜像仓库引用及默认分支"
  diff -u <(git ls-remote "$SOURCE_URL" | grep -E $'\t(HEAD|refs/heads/|refs/tags/)' | sort) \
    <(git ls-remote "$(mirror_url "$ROOT_REPO")" | grep -E $'\t(HEAD|refs/heads/|refs/tags/)' | sort)
  git ls-remote --symref "$(mirror_url "$ROOT_REPO")" HEAD | grep -q $'ref: refs/heads/main\tHEAD' || fail "HEAD is not main"
  step "4/4 克隆镜像并验证 HEAD 对象"
  clone_mirror "$dest"
  git -C "$dest" cat-file -e "$(git -C "$dest" rev-parse HEAD)^{commit}"
  pass protocol-basics "$started"
}

scenario_clone_modes() {
  local started="$(date +%s)" tag
  step "1/5 等待镜像就绪"
  wait_ready
  step "2/5 验证浅克隆及解除浅克隆"
  clone_mirror "$WORK/shallow" --depth=1 --single-branch --branch main
  [ "$(git -C "$WORK/shallow" rev-parse --is-shallow-repository)" = true ] || fail "not shallow"
  git -C "$WORK/shallow" fetch --unshallow origin
  step "3/5 验证禁用 Tag 后按需抓取 Tag"
  clone_mirror "$WORK/no-tags" --no-tags --depth=1
  tag="$(git ls-remote --tags "$SOURCE_URL" | awk '!/\^\{\}$/{sub("refs/tags/","",$2);print $2;exit}')"
  [ -n "$tag" ] || fail "fixture has no tag"
  git -C "$WORK/no-tags" fetch origin "refs/tags/$tag:refs/tags/$tag"
  step "4/5 验证 Partial Clone"
  clone_mirror "$WORK/partial" --filter=blob:none --no-checkout
  [ "$(git -C "$WORK/partial" config --get remote.origin.promisor)" = true ] || fail "partial clone degraded"
  git -C "$WORK/partial" checkout main
  step "5/5 验证 Sparse Checkout"
  clone_mirror "$WORK/sparse" --filter=blob:none --no-checkout
  git -C "$WORK/sparse" sparse-checkout init --no-cone
  git -C "$WORK/sparse" sparse-checkout set README.md
  git -C "$WORK/sparse" checkout main
  [ -f "$WORK/sparse/README.md" ] && [ ! -f "$WORK/sparse/random_file.bin" ] || fail "sparse checkout failed"
  pass clone-modes "$started"
}

scenario_fetch_incremental() {
  local started="$(date +%s)" branch="mirror-fetch-$BUILD_UID" src="$WORK/fetch-src"
  local sha
  step "1/7 等待镜像就绪"
  wait_ready
  step "2/7 克隆镜像作为增量 Fetch 客户端"
  clone_mirror "$WORK/fetch-client"
  step "3/7 在 GitHub 源仓库创建第 1 个测试提交"
  new_branch "$src" "$branch" 1
  sha="${BRANCH_SHAS[-1]}"
  step "4/7 等待第 1 个提交同步并从镜像 Fetch"
  wait_ref "refs/heads/$branch" "$sha"
  trace_git dev.bkcode.woa.com github.com "$WORK/fetch.trace" git -C "$WORK/fetch-client" \
    fetch origin "refs/heads/$branch:refs/remotes/origin/$branch"
  [ "$(git -C "$WORK/fetch-client" rev-parse "origin/$branch")" = "$sha" ] || fail "incremental fetch mismatch"
  log "增量 Fetch 校验通过: index=1 sha=$sha"
  step "5/7 在同一分支创建第 2 个测试提交"
  push_test_commit "$src" "$branch" 2
  sha="${BRANCH_SHAS[-1]}"
  step "6/7 等待第 2 个提交同步并再次从镜像 Fetch"
  wait_ref "refs/heads/$branch" "$sha"
  trace_git dev.bkcode.woa.com github.com "$WORK/fetch.trace" git -C "$WORK/fetch-client" \
    fetch origin "refs/heads/$branch:refs/remotes/origin/$branch"
  [ "$(git -C "$WORK/fetch-client" rev-parse "origin/$branch")" = "$sha" ] || fail "incremental fetch mismatch"
  log "增量 Fetch 校验通过: index=2 sha=$sha"
  step "7/7 删除源分支并验证镜像删除同步"
  delete_refs "$src" "refs/heads/$branch"; wait_ref_absent "refs/heads/$branch"
  pass fetch-incremental "$started"
}

scenario_ref_mutations() {
  local started="$(date +%s)" branch="mirror-mutate-$BUILD_UID" light="light-$BUILD_UID" ann="ann-$BUILD_UID"
  local src="$WORK/mutate-src" forced
  step "1/5 等待镜像就绪并创建测试分支"
  wait_ready; new_branch "$src" "$branch"
  step "2/5 创建并推送轻量 Tag 与附注 Tag"
  git -C "$src" tag "$light" "${BRANCH_SHAS[0]}"
  git -C "$src" tag -a "$ann" -m 'mirror annotated tag' "${BRANCH_SHAS[0]}"
  git -C "$src" push origin "refs/tags/$light" "refs/tags/$ann"
  wait_ref "refs/tags/$light" "$(git -C "$src" rev-parse "refs/tags/$light")"
  wait_ref "refs/tags/$ann" "$(git -C "$src" rev-parse "refs/tags/$ann")"
  step "3/5 创建孤儿提交并强制更新分支"
  git -C "$src" checkout --orphan "orphan-$BUILD_UID"
  git -C "$src" rm -rf .
  echo forced >"$src/forced-history.txt"
  git -C "$src" add forced-history.txt
  git -C "$src" commit -m 'forced history'
  forced="$(git -C "$src" rev-parse HEAD)"
  git -C "$src" push --force origin "HEAD:refs/heads/$branch"
  step "4/5 验证镜像收到强制更新"
  wait_ref "refs/heads/$branch" "$forced"
  step "5/5 删除分支与 Tag 并验证镜像删除同步"
  delete_refs "$src" "refs/heads/$branch" "refs/tags/$light" "refs/tags/$ann"
  wait_ref_absent "refs/heads/$branch"; wait_ref_absent "refs/tags/$light"; wait_ref_absent "refs/tags/$ann"
  pass ref-mutations "$started"
}

checkout_once() {
  local url="$1" ref="$2" dest="$3" expected="$4" forbidden="$5"
  log "模拟 Checkout Shell: url=$url ref=$ref depth=${FETCH_DEPTH:-1} dest=$dest"
  mkdir -p "$dest"; git -C "$dest" init; git -C "$dest" remote add origin "$url"
  trace_git "$expected" "$forbidden" "$WORK/checkout.trace" git -C "$dest" fetch --depth "${FETCH_DEPTH:-1}" origin "$ref"
  git -C "$dest" checkout --detach FETCH_HEAD
}

scenario_checkout_shell_reference() {
  local started="$(date +%s)" ref="${CHECKOUT_REF:-main}"
  step "1/4 等待镜像就绪"
  wait_ready
  step "2/4 使用参考 Shell 从镜像 Checkout"
  checkout_once "$(mirror_url "$ROOT_REPO")" "$ref" "$WORK/checkout-mirror" dev.bkcode.woa.com github.com
  step "3/4 使用参考 Shell 从 GitHub 源仓库 Checkout"
  checkout_once "$SOURCE_URL" "$ref" "$WORK/checkout-source" github.com dev.bkcode.woa.com
  step "4/4 比对提交、目录树和 Submodule gitlink"
  for expr in HEAD 'HEAD^{tree}' HEAD:apisix; do
    [ "$(git -C "$WORK/checkout-mirror" rev-parse "$expr")" = "$(git -C "$WORK/checkout-source" rev-parse "$expr")" ] ||
      fail "checkout result differs: $expr"
  done
  pass checkout-shell-reference "$started"
}

scenario_push_isolation() {
  local started="$(date +%s)" branch="mirror-push-$BUILD_UID" dest="$WORK/push" sha
  step "1/5 等待镜像就绪并克隆"
  wait_ready; clone_mirror "$dest"
  step "2/5 配置 Push URL 指向 GitHub 源仓库"
  git -C "$dest" remote set-url --push origin "$SOURCE_URL"
  git -C "$dest" config user.name 'BK-Code Mirror Test'; git -C "$dest" config user.email mirror-test@bkcode.invalid
  git -C "$dest" checkout -b "$branch"; echo push >"$dest/$branch"; git -C "$dest" add "$branch"; git -C "$dest" commit -m push-isolation
  sha="$(git -C "$dest" rev-parse HEAD)"
  step "3/5 验证 Push 只访问 GitHub"
  trace_git github.com dev.bkcode.woa.com "$WORK/push.trace" git -C "$dest" push origin "HEAD:refs/heads/$branch"
  step "4/5 验证 Push 结果同步到镜像且镜像拒绝写入"
  wait_ref "refs/heads/$branch" "$sha"
  git -C "$dest" push "$(mirror_url "$ROOT_REPO")" "HEAD:refs/heads/rejected-$BUILD_UID" && fail "mirror accepted push" || true
  step "5/5 删除测试分支并验证镜像删除同步"
  delete_refs "$dest" "refs/heads/$branch"; wait_ref_absent "refs/heads/$branch"
  pass push-isolation "$started"
}

scenario_submodule() {
  local started="$(date +%s)" dest="$WORK/submodule"
  step "1/4 等待主仓库和 Submodule 镜像就绪"
  wait_ready; wait_ready apache/apisix 2700
  step "2/4 配置 Submodule URL 改写到镜像"
  git config --global "url.$(mirror_url apache/apisix).insteadOf" https://github.com/apache/apisix.git
  step "3/4 克隆主仓库并通过镜像拉取 Submodule"
  clone_mirror "$dest"
  trace_git dev.bkcode.woa.com github.com "$WORK/submodule.trace" git -C "$dest" submodule update --init apisix
  step "4/4 验证 Submodule 提交与 gitlink 一致"
  [ "$(git -C "$dest" rev-parse HEAD:apisix)" = "$(git -C "$dest/apisix" rev-parse HEAD)" ] || fail "apisix gitlink mismatch"
  pass submodule "$started"
}

scenario_nested_relative_submodule() {
  local started="$(date +%s)" dest="$WORK/nested"
  step "1/4 检查嵌套 Fixture 并等待各级镜像就绪"
  for repo in tencent-bkc/10repo-sub-child tencent-bkc/10repo-sub-leaf; do
    curl -fsS "https://api.github.com/repos/$repo" >/dev/null || fail "fixture missing: $repo"
    wait_ready "$repo" 2700
  done
  wait_ready apache/apisix 2700; wait_ready
  step "2/4 配置绝对 Submodule URL 改写到镜像"
  git config --global "url.$(mirror_url apache/apisix).insteadOf" https://github.com/apache/apisix.git
  step "3/4 克隆主仓库并递归拉取 Submodule"
  clone_mirror "$dest"
  trace_git dev.bkcode.woa.com github.com "$WORK/nested.trace" git -C "$dest" submodule update --init --recursive
  step "4/4 验证两级相对 Submodule gitlink"
  [ "$(git -C "$dest" rev-parse HEAD:nested/child)" = "$(git -C "$dest/nested/child" rev-parse HEAD)" ] || fail "child mismatch"
  [ "$(git -C "$dest/nested/child" rev-parse HEAD:nested/leaf)" = "$(git -C "$dest/nested/child/nested/leaf" rev-parse HEAD)" ] || fail "leaf mismatch"
  pass nested-relative-submodule "$started"
}

lfs_verify() {
  local repo="$1"
  log "校验 LFS 对象数量、大小和 SHA-256: repo=$repo"
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
print(f"LFS objects verified: {checked}")
PY
}

scenario_lfs() {
  local started="$(date +%s)" dest="$WORK/lfs"
  step "1/5 检查 Git LFS 并等待镜像就绪"
  require git-lfs; wait_ready
  step "2/5 克隆镜像并初始化 Git LFS"
  clone_mirror "$dest"
  git -C "$dest" lfs install --local
  step "3/5 从镜像 Fetch 全部 LFS 对象并校验"
  trace_git dev.bkcode.woa.com github.com "$WORK/lfs.trace" git -C "$dest" lfs fetch --all
  git -C "$dest" lfs checkout; lfs_verify "$dest"
  step "4/5 清空本地 LFS 缓存后从镜像 Pull"
  rm -rf "$dest/.git/lfs/objects"
  trace_git dev.bkcode.woa.com github.com "$WORK/lfs-pull.trace" git -C "$dest" lfs pull
  step "5/5 再次校验 LFS 对象完整性"
  lfs_verify "$dest"
  pass lfs "$started"
}

scenario_readonly() {
  local started="$(date +%s)" dest="$WORK/readonly" source_before mirror_before
  step "1/4 等待镜像就绪并记录变更前引用"
  wait_ready; source_before="$(git ls-remote "$SOURCE_URL")"; mirror_before="$(git ls-remote "$(mirror_url "$ROOT_REPO")")"
  step "2/4 克隆镜像并尝试推送分支"
  clone_mirror "$dest"; git -C "$dest" checkout -b "readonly-$BUILD_UID"
  git -C "$dest" push origin HEAD && fail "mirror accepted branch push" || true
  log "镜像已按预期拒绝分支 Push"
  step "3/4 尝试向镜像推送 Tag"
  git -C "$dest" tag "readonly-$BUILD_UID"; git -C "$dest" push origin --tags && fail "mirror accepted tag push" || true
  log "镜像已按预期拒绝 Tag Push"
  step "4/4 验证拒绝 Push 后源仓库与镜像引用均未变化"
  [ "$source_before" = "$(git ls-remote "$SOURCE_URL")" ] && [ "$mirror_before" = "$(git ls-remote "$(mirror_url "$ROOT_REPO")")" ] ||
    fail "rejected push changed refs"
  pass readonly "$started"
}

scenario_path_occupied() {
  local started="$(date +%s)" group_id
  step "1/4 删除镜像仓库并确保测试仓库组存在"
  delete_repo "$ROOT_REPO"; group_detail
  if [ "$HTTP_STATUS" = 404 ]; then
    api POST /api/v1/groups '{"name":"tencent-bkc","displayName":"tencent-bkc","groupType":"INTERNAL"}'
    [ "$HTTP_STATUS" = 201 ] || fail "create group failed"
  fi
  group_id="$(printf '%s' "$HTTP_BODY" | json_get data.id)"
  step "2/4 在相同路径创建普通仓库"
  api POST /api/v1/repos "{\"groupId\":$group_id,\"name\":\"10repo\",\"displayName\":\"ordinary collision\"}"
  [ "$HTTP_STATUS" = 201 ] || fail "create ordinary repository failed"
  step "3/4 验证路径占用时回源且不覆盖普通仓库"
  decision; [ "$DECISION_STATUS" = 307 ] || fail "occupied path did not fall back"
  log "路径占用路由决策: http=$DECISION_STATUS location=${DECISION_LOCATION:-none}"
  repo_detail "$ROOT_REPO"; [ "$(printf '%s' "$HTTP_BODY" | json_get data.mirror)" = false ] || fail "ordinary repo overwritten"
  mirror_detail "$ROOT_REPO"; [ "$HTTP_STATUS" = 404 ] || fail "ordinary repo gained mirror config"
  step "4/4 删除普通仓库并验证镜像可重新导入"
  delete_repo "$ROOT_REPO"; wait_ready
  pass path-occupied "$started"
}

scenario_large_repo() {
  local started="$(date +%s)" url="${LARGE_REPO_URL:-}" repo default dest
  step "1/5 校验大仓库参数并读取默认分支"
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(\.git)?/?$ ]] || fail "invalid LARGE_REPO_URL"
  repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  default="$(curl -fsS "https://api.github.com/repos/$repo" | json_get default_branch)"
  log "大仓库信息: repo=$repo default_branch=$default"
  step "2/5 等待大仓库镜像就绪"
  wait_ready "$repo" "$(( ${LARGE_REPO_TIMEOUT_MINUTES:-60}*60 ))"
  step "3/5 连续执行两次浅克隆并记录大小"
  for i in 1 2; do
    log "大仓库浅克隆: run=$i repo=$repo branch=$default"
    dest="$WORK/large-shallow-$i"; time git clone --depth=1 --single-branch --branch "$default" "$(mirror_url "$repo")" "$dest"
    du -sh "$dest" "$dest/.git"
  done
  step "4/5 连续执行两次 Partial Clone"
  for i in 1 2; do
    log "大仓库 Partial Clone: run=$i repo=$repo"
    dest="$WORK/large-partial-$i"; time git clone --filter=blob:none --no-checkout "$(mirror_url "$repo")" "$dest"
    [ "$(git -C "$dest" config --get remote.origin.promisor)" = true ] || fail "partial clone degraded"
    git -C "$dest" checkout "$default"
  done
  step "5/5 按参数决定是否执行完整克隆"
  if [ "${LARGE_REPO_FULL_CLONE:-false}" = true ]; then
    log "执行解除浅克隆，拉取完整仓库"
    git -C "$WORK/large-shallow-1" fetch --unshallow origin
  else
    log "跳过完整克隆: LARGE_REPO_FULL_CLONE=${LARGE_REPO_FULL_CLONE:-false}"
  fi
  pass large-repo "$started"
}

log "验收开始: target=$TARGET_URL root_repo=$ROOT_REPO build_uid=$BUILD_UID poll_minutes=$POLL_MINUTES"

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
