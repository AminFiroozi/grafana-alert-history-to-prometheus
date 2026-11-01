#!/bin/sh
# migrate.sh - run the whole "Grafana alert history to Prometheus" migration.
#
# Stages: preflight, dump, convert, blocks, copy, verify, cleanup (plus the
# separate actions rollback and undo-blocks). Run "migrate.sh --help" for every
# option, the exit codes and examples. Plain POSIX sh. It installs and downloads
# nothing: python3, curl, kubectl (or oc), and promtool (or docker with a local
# image) must already exist on this host. The only other files it needs are the
# Python tools next to it (--tool-dir).
set -eu
LC_ALL=C
export LC_ALL

PROG=migrate.sh
NL='
'
# exit codes (documented in --help)
E_USAGE=2; E_PREFLIGHT=3; E_DUMP=4; E_CONVERT=5; E_BLOCKS=6; E_COPY=7; E_ROLLBACK=9; E_ABORT=10

case $0 in */*) _d=${0%/*} ;; *) _d=. ;; esac
SELF_DIR=$(cd "$_d" && pwd -P)

# ----------------------------------------------------------------------------
# internal state (never taken from the environment)
SCRATCH=; RUN_N=0; PF_PID=; LOGF=; MASKS=; DRY=0; PROM_BASE=; CURLCFG=; GCURLCFG=
COLOR=0; JOB_PIDS=; STAGE_LIST=; PT_MODE=; PT_BIN=; PT_IMG=; UNITS=; PRIMARY=
DATA_DIR=; F_VERSION=; F_PATH=; F_RET_TIME=; F_RET_SIZE=; F_LOOKBACK=; F_ADMIN=
PI_OK=0; PI_ERR=; PF_FAIL=0; BLOCK_LIST=; STATE_FILE=; MARKER=; PROM_READY=0
T_OPT=; T_VAR=; T_KIND=; T_DEF=; TRIMMED=; MODE_ACTION=; DUMP_PATH=

# ----------------------------------------------------------------------------
# option table:  long-name|VARIABLE|kind|default
# kind: v = value, f = flag (yes/no), m = repeatable value (one per line)
# The VARIABLE name is also the environment variable name (MIGRATE_<VARIABLE>
# wins over <VARIABLE> if both are set) and the KEY in a --config file.
OPT_TABLE='config|CONFIG|v|
print-config|PRINT_CONFIG|f|0
source-type|SOURCE_TYPE|v|
history-repo|HISTORY_REPO|v|
history-dir|HISTORY_DIR|v|
rules-dir|RULES_DIR|v|@default@
state|STATE|v|
grafana-url|GRAFANA_URL|v|
token|GRAFANA_TOKEN|v|
user|GRAFANA_USER|v|
password|GRAFANA_PASSWORD|v|
org-id|ORG_ID|v|
insecure|INSECURE|f|0
grafana-ca-cert|GRAFANA_CA_CERT|v|
grafana-header|GRAFANA_HEADER|m|
grafana-path-prefix|GRAFANA_PATH_PREFIX|v|
limit|LIMIT|v|5000
csv|CSV|v|
csv-from|CSV_FROM|v|
csv-to|CSV_TO|v|
dump|DUMP|v|
from|FROM|v|
to|TO|v|
source-label|SOURCE_LABEL|v|grafana-history
source-label-name|SOURCE_LABEL_NAME|v|source
metric-name|METRIC_NAME|v|ALERTS_HISTORY
extra-label|EXTRA_LABEL|m|
step|STEP|v|1m
split|SPLIT|v|486h
max-block-duration|MAX_BLOCK_DURATION|v|
deleted-rule-end|DELETED_RULE_END|v|last-event
workdir|WORKDIR|v|./migrate-work
tmpdir|TMPDIR|v|
log-file|LOG_FILE|v|
tool-dir|TOOL_DIR|v|
target|TARGET|v|k8s
kubectl|KUBECTL|v|kubectl
kubeconfig|KUBECONFIG|v|
kube-context|KUBE_CONTEXT|v|
namespace|NAMESPACE|v|
pod|POD|v|
container|CONTAINER|v|prometheus
replicas|REPLICAS|v|
selector|SELECTOR|v|
copy-method|COPY_METHOD|v|cp
chown|CHOWN|v|
chmod|CHMOD|v|
tmp-suffix|TMP_SUFFIX|v|.tmp-for-creation
docker-container|DOCKER_CONTAINER|v|
docker-exec-args|DOCKER_EXEC_ARGS|v|
local-data-path|LOCAL_DATA_PATH|v|
data-path|DATA_PATH|v|
port-forward|PORT_FORWARD|f|0
pod-port|POD_PORT|v|9090
prom-url|PROM_URL|v|
prom-user|PROM_USER|v|
prom-password|PROM_PASSWORD|v|
prom-token|PROM_TOKEN|v|
prom-ca-cert|PROM_CA_CERT|v|
prom-insecure|PROM_INSECURE|f|0
prom-header|PROM_HEADER|m|
prom-path-prefix|PROM_PATH_PREFIX|v|
prom-version|PROM_VERSION|v|
python|PYTHON|v|python3
curl|CURL|v|curl
docker|DOCKER|v|docker
promtool|PROMTOOL|v|
promtool-image|PROMTOOL_IMAGE|v|
docker-extra-args|DOCKER_EXTRA_ARGS|v|
pull|PULL|f|0
http-proxy|HTTP_PROXY|v|
no-proxy|NO_PROXY|v|
parallel|PARALLEL|v|4
reload-timeout|RELOAD_TIMEOUT|v|300
reload-interval|RELOAD_INTERVAL|v|5
min-free-disk-factor|MIN_FREE_DISK_FACTOR|v|4
local-min-free-gb|LOCAL_MIN_FREE_GB|v|5
max-blocks|MAX_BLOCKS|v|100
stage|STAGE|v|all
dry-run|DRY_RUN|f|0
plan|PLAN|f|0
yes|YES|f|0
confirm-string|CONFIRM_STRING|v|
skip-verify|SKIP_VERIFY|f|0
keep-om|KEEP_OM|f|0
keep-blocks|KEEP_BLOCKS|f|0
force-existing|FORCE_EXISTING|f|0
rollback|ROLLBACK|f|0
undo-blocks|UNDO_BLOCKS|f|0
undo-list|UNDO_LIST|v|
no-color|NO_COLOR|f|0
quiet|QUIET|f|0'

# variables whose value must never be printed
SECRET_VARS=' GRAFANA_TOKEN GRAFANA_PASSWORD PROM_PASSWORD PROM_TOKEN '
# repeatable header variables: the part after "Name:" is secret
HEADER_VARS=' GRAFANA_HEADER PROM_HEADER '

# ----------------------------------------------------------------------------
# logging
QUIET=0

mask_text() {
    if [ -n "$MASKS" ]; then
        MIGRATE_MASKS=$MASKS awk 'BEGIN{n=split(ENVIRON["MIGRATE_MASKS"],m,"\n")}
{l=$0;for(i=1;i<=n;i++){s=m[i];if(s=="")continue;o="";while((p=index(l,s))>0){o=o substr(l,1,p-1) "****";l=substr(l,p+length(s))}l=o l}print l}'
    else
        cat
    fi
}

# log LEVEL message...   (stderr and log file, secrets masked, UTC timestamp)
log() {
    _lv=$1; shift
    _msg=$(printf '%s\n' "$*" | mask_text)
    _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    _show=1
    if [ "$QUIET" = 1 ]; then
        case $_lv in INFO|CMD|OUT|OK|DBG) _show=0 ;; esac
    fi
    case $_lv in DBG) _show=0 ;; esac
    if [ "$_show" = 1 ]; then
        if [ "$COLOR" = 1 ]; then
            case $_lv in
                ERROR|FAIL) _c='\033[31m' ;;
                WARN) _c='\033[33m' ;;
                OK|PASS) _c='\033[32m' ;;
                *) _c='' ;;
            esac
            printf "%s ${_c}[%s]\033[0m %s\n" "$_ts" "$_lv" "$_msg" >&2
        else
            printf '%s [%s] %s\n' "$_ts" "$_lv" "$_msg" >&2
        fi
    fi
    if [ -n "$LOGF" ]; then
        printf '%s [%s] %s\n' "$_ts" "$_lv" "$_msg" >> "$LOGF" 2>/dev/null || true
    fi
}

die() {
    _dc=$1; shift
    log ERROR "$*"
    exit "$_dc"
}

# fatal unless a plain --dry-run is active (then it is only a warning)
fail_or_warn() {
    _fc=$1; shift
    if [ "$DRY" = 1 ] && [ "$PLAN" != 1 ]; then
        log WARN "dry-run, would fail: $*"
    else
        die "$_fc" "$*"
    fi
}

stream_log() {
    while IFS= read -r _sl || [ -n "$_sl" ]; do
        log OUT "$_sl"
    done
}

# shell-quote one word for display
sq() {
    case $1 in
        ''|*[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}
quote_args() {
    _qo=
    for _qa in "$@"; do _qo="$_qo $(sq "$_qa")"; done
    printf '%s' "${_qo# }"
}

# run_core STDIN_MODE cmd args...: log the command, run it (unless dry-run),
# send its output to the log, return its exit code. STDIN_MODE 0 = /dev/null.
run_core() {
    _rm=$1; shift
    log CMD "$(quote_args "$@")"
    if [ "$DRY" = 1 ]; then return 0; fi
    RUN_N=$((RUN_N + 1))
    _rcf="$SCRATCH/rc.$RUN_N"
    if [ "$_rm" = 0 ]; then
        { set +e; "$@" 2>&1; echo $? > "$_rcf"; } < /dev/null | stream_log
    else
        { set +e; "$@" 2>&1; echo $? > "$_rcf"; } | stream_log
    fi
    _rc=$(cat "$_rcf" 2>/dev/null || echo 1)
    rm -f "$_rcf"
    return "$_rc"
}
run() { run_core 0 "$@"; }
run_i() { run_core 1 "$@"; }

# ----------------------------------------------------------------------------
# option table helpers
tbl_find() { # opt|var NAME -> sets T_OPT T_VAR T_KIND T_DEF
    _tm=$1; _tv=$2
    while IFS='|' read -r _fo _fv _fk _fd; do
        case $_tm in
            opt) [ "$_fo" = "$_tv" ] || continue ;;
            var) [ "$_fv" = "$_tv" ] || continue ;;
        esac
        T_OPT=$_fo; T_VAR=$_fv; T_KIND=$_fk; T_DEF=$_fd
        return 0
    done <<EOF
$OPT_TABLE
EOF
    return 1
}

getvar() { eval "printf '%s' \"\${$1-}\""; }
setvar() { eval "$1=\$2"; }
is_set() { eval "[ \"\${$1+x}\" = x ]"; }

trim() { TRIMMED=${1#"${1%%[![:space:]]*}"}; TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}; }

# set_val SOURCE VAR VALUE: store one value coming from SOURCE (default|config|env|cli)
set_val() {
    _sv=$2; _vv=$3
    tbl_find var "$_sv" || die $E_USAGE "internal: unknown variable $_sv"
    case $T_KIND in
        f)
            case $_vv in
                1|yes|YES|Yes|true|TRUE|True|on|ON|y|Y) _vv=1 ;;
                0|no|NO|No|false|FALSE|False|off|OFF|n|N|'') _vv=0 ;;
                *) die $E_USAGE "$_sv: not a yes/no value: $_vv" ;;
            esac
            setvar "$_sv" "$_vv"
            ;;
        m)
            if [ "$(getvar "SRC_$_sv")" != "$1" ]; then setvar "$_sv" ""; fi
            _cur=$(getvar "$_sv")
            # a value may carry several lines (environment variables)
            while IFS= read -r _line || [ -n "$_line" ]; do
                [ -n "$_line" ] || continue
                if [ -n "$_cur" ]; then _cur="$_cur$NL$_line"; else _cur=$_line; fi
            done <<EOF
$_vv
EOF
            setvar "$_sv" "$_cur"
            ;;
        *) setvar "$_sv" "$_vv" ;;
    esac
    setvar "SRC_$_sv" "$1"
}

apply_defaults() {
    while IFS='|' read -r _o _v _k _d; do
        setvar "$_v" "$_d"
        setvar "SRC_$_v" default
    done <<EOF
$OPT_TABLE
EOF
}

# remember which variables the caller's environment had, before defaults overwrite them
snapshot_env() {
    while IFS='|' read -r _o _v _k _d; do
        if is_set "MIGRATE_$_v"; then
            setvar "ENVV_$_v" "$(getvar "MIGRATE_$_v")"; setvar "ENVS_$_v" 1
        elif is_set "$_v"; then
            setvar "ENVV_$_v" "$(getvar "$_v")"; setvar "ENVS_$_v" 1
        else
            case $_v in
                GRAFANA_TOKEN) if is_set TOKEN; then setvar "ENVV_$_v" "$TOKEN"; setvar "ENVS_$_v" 1; fi ;;
                GRAFANA_PASSWORD) if is_set PASSWORD; then setvar "ENVV_$_v" "$PASSWORD"; setvar "ENVS_$_v" 1; fi ;;
            esac
        fi
    done <<EOF
$OPT_TABLE
EOF
}

apply_env() {
    while IFS='|' read -r _o _v _k _d; do
        if [ "$(getvar "ENVS_$_v" 2>/dev/null || true)" = 1 ]; then
            set_val env "$_v" "$(getvar "ENVV_$_v")"
        fi
    done <<EOF
$OPT_TABLE
EOF
}

# KEY=VALUE lines. Never sourced or evaluated. KEY is a variable name (or the
# long option name); '#' starts a comment line; matching quotes around the value are removed.
parse_config() {
    _cf=$1
    [ -f "$_cf" ] || die $E_USAGE "config file not found: $_cf"
    [ -r "$_cf" ] || die $E_USAGE "config file not readable: $_cf"
    _ln=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _ln=$((_ln + 1))
        trim "$_line"; _line=$TRIMMED
        case $_line in ''|'#'*) continue ;; esac
        case $_line in
            *=*) ;;
            *) die $E_USAGE "$_cf:$_ln: expected KEY=VALUE" ;;
        esac
        trim "${_line%%=*}"; _k=$TRIMMED
        trim "${_line#*=}"; _v=$TRIMMED
        case $_v in
            \"*\") _v=${_v#\"}; _v=${_v%\"} ;;
            \'*\') _v=${_v#\'}; _v=${_v%\'} ;;
        esac
        _k=$(printf '%s' "$_k" | tr 'a-z-' 'A-Z_')
        tbl_find var "$_k" || die $E_USAGE "$_cf:$_ln: unknown key '$_k'"
        [ "$_k" != CONFIG ] || die $E_USAGE "$_cf:$_ln: 'config' cannot be set inside a config file"
        set_val config "$_k" "$_v"
    done < "$_cf"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --*=*)
                _o=${1%%=*}; _v=${1#*=}
                if tbl_find opt "${_o#--}" && [ "$T_KIND" = f ]; then
                    set_val cli "$T_VAR" "$_v"; shift; continue
                fi
                shift; set -- "$_o" "$_v" "$@"; continue
                ;;
        esac
        case $1 in
            -h|--help) shift; continue ;;
            --*)
                tbl_find opt "${1#--}" || die $E_USAGE "unknown option: $1 (see --help)"
                if [ "$T_KIND" = f ]; then
                    set_val cli "$T_VAR" 1; shift
                else
                    [ $# -ge 2 ] || die $E_USAGE "option $1 needs a value"
                    set_val cli "$T_VAR" "$2"; shift 2
                fi
                ;;
            *) die $E_USAGE "unexpected argument: $1 (see --help)" ;;
        esac
    done
}

# find "--config FILE" and "--help" before the full parse
prescan() {
    CFG_CLI=
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --config=*) CFG_CLI=${1#--config=} ;;
            --config) [ $# -ge 2 ] || die $E_USAGE "option --config needs a value"; CFG_CLI=$2; shift ;;
        esac
        shift
    done
}

print_config() {
    log INFO "resolved settings (source in brackets; secrets hidden):"
    while IFS='|' read -r _o _v _k _d; do
        _val=$(getvar "$_v"); _src=$(getvar "SRC_$_v")
        if [ "$_v" = RULES_DIR ] && [ "$_val" = '@default@' ]; then continue; fi
        [ -n "$_val" ] || continue
        if [ "$_k" = f ] && [ "$_val" = 0 ]; then continue; fi
        case $SECRET_VARS in
            *" $_v "*) log INFO "  --$_o = **** [$_src]"; continue ;;
        esac
        case $HEADER_VARS in
            *" $_v "*)
                while IFS= read -r _h; do
                    log INFO "  --$_o = ${_h%%:*}: **** [$_src]"
                done <<EOF
$_val
EOF
                continue ;;
        esac
        if [ "$_k" = m ]; then
            while IFS= read -r _h; do log INFO "  --$_o = $_h [$_src]"; done <<EOF
$_val
EOF
        else
            log INFO "  --$_o = $_val [$_src]"
        fi
    done <<EOF
$OPT_TABLE
EOF
}

# ----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
migrate.sh - move Grafana alert state history into a Prometheus TSDB, end to end.

  export/read history -> OpenMetrics -> TSDB blocks (promtool) -> copy into the
  Prometheus data directory -> check the result against the source.

It installs and downloads nothing. These must already exist on this host:
python3 (3.8 or newer), curl, and kubectl (or oc) for a Kubernetes target or
docker for a docker target, plus promtool (or docker with a promtool image that
is already present). The only other files needed are the Python tools in
--tool-dir (default: the folder this script is in), so the whole repo folder can
be copied to a host as it is.

USAGE
  migrate.sh [--config FILE] [options]
  migrate.sh --help

Every option can also be set three other ways. Order of priority, highest first:
  1. the command line            --namespace monitoring
  2. an environment variable     NAMESPACE=monitoring   (MIGRATE_NAMESPACE wins over NAMESPACE)
  3. a config file (--config)    one KEY=VALUE per line, KEY = the variable name, '#' for comments
  4. the default shown below
The variable name is the option name in capitals with '-' turned into '_'.
Three exceptions to avoid clashes with common variables: --token is GRAFANA_TOKEN
(TOKEN also works), --user is GRAFANA_USER, --password is GRAFANA_PASSWORD
(PASSWORD also works). Yes/no options take 1/yes/true/on or 0/no/false/off in
the environment and in the config file. Repeatable options (marked "repeatable")
are repeated on the command line, and use one line each in the environment and
in the config file. Config files are read as plain text, never run.
At the start of every run the resolved settings are printed with the place each
came from; secrets are hidden. --print-config prints them and stops.
Secrets: prefer the environment or a config file with mode 600 over --token and
--password, because command-line arguments are visible to other users in "ps".

STAGES  (--stage NAME, default all; each stage keeps its result under --workdir
         so you can run them one at a time and resume)
  preflight   check tools, Prometheus, target, disk space, retention, existing data
  dump        read the history into <workdir>/dump.json
  convert     dump -> OpenMetrics files in <workdir>/om
  blocks      OpenMetrics -> TSDB blocks in <workdir>/blocks (promtool); deletes the
              OpenMetrics files afterwards unless --keep-om
  copy        copy blocks into the target data directory, wait until Prometheus
              loads them. This is the only stage that changes the target.
  verify      compare the dump with what Prometheus now returns (PASS or FAIL)
  cleanup     delete <workdir>/om and <workdir>/blocks (not the dump, log or undo list)
  all         preflight dump convert blocks copy verify cleanup
  rollback    (also --rollback) delete the imported series with the admin API
  undo-blocks (also --undo-blocks) remove only the block directories listed in the
              undo list, see below

SOURCE (one of)
  --source-type git --history-repo DIR   alert-history day files written by grafana-git-sync
        --history-dir DIR     default: <history-repo>/alert-history
        --rules-dir DIR       rule map folder; '' means none; default: <repo>/alerting/rules
        --state FILE          default: <repo>/.grafana-sync/state.json
  --source-type grafana --grafana-url URL (--token T | --user U --password P)
        --org-id N            Grafana organisation (default: the user's current one)
        --insecure            skip TLS verification of Grafana
        --grafana-ca-cert F   CA bundle (PEM) for Grafana
        --grafana-header 'Name: value'   extra HTTP header (repeatable)
        --grafana-path-prefix /grafana   when Grafana is served under a sub path
        --limit N             rows per API call (default 5000)
  --source-type csv --csv FILE --csv-from MS --csv-to MS
                              SQL export of the annotation table (see tool/csv_to_dump.py)
  --source-type dump --dump FILE         use an existing dump, skip the export

DATA
  --from TIME               first moment to import: epoch seconds or ms, YYYY-MM-DD,
                            RFC3339 (default 1 = everything)
  --to TIME                 last moment (default: now; for git: the sync cursor)
  --source-label NAME       value of the label that marks these series (default grafana-history)
  --source-label-name NAME  name of that label (default source)
  --metric-name NAME        metric name (default ALERTS_HISTORY)
  --extra-label K=V         one more label on every series (repeatable)
  --step 1m                 sample spacing inside a firing interval; must be below
                            Prometheus' lookback delta (5m by default)
  --split 486h              one OpenMetrics file and one block per window of this
                            length; 'none' = a single file
  --max-block-duration D    promtool block length (default: same as --split)
  --deleted-rule-end last-event|export   where open intervals of deleted rules stop
  --workdir DIR             all files of the run (default ./migrate-work)
  --tmpdir DIR              folder for small temporary files (default /tmp)

TARGET
  --target k8s|docker|local   where the Prometheus data directory is (default k8s)
  Kubernetes:
    --kubectl BIN           kubectl binary (use 'oc' for OpenShift)
    --kubeconfig FILE, --kube-context CTX, --namespace NS
    --pod NAME              Prometheus pod            --container NAME (default prometheus)
    --selector LABEL=VALUE  find the pods by label instead of --pod (all matches get the blocks)
    --replicas "pod2 pod3"  extra pods to copy the blocks into (HA pairs)
    --copy-method cp|exec-tar|exec-cat
                            cp = kubectl cp (needs tar in the image); exec-tar = tar piped
                            through kubectl exec (needs tar); exec-cat = one 'cat >' per file
                            (needs only sh and cat in the image)
    --chown USER:GROUP, --chmod MODE   applied inside the target before the final rename
    --tmp-suffix S          temporary name suffix (default .tmp-for-creation)
    --port-forward          start 'kubectl port-forward' to the pod for all Prometheus calls
                            (use instead of --prom-url; stops when the script ends)
    --pod-port N            Prometheus port inside the pod (default 9090)
  Docker:
    --docker-container NAME the Prometheus container    --docker-exec-args "-u 0"
  Local directory (VM, systemd, bare metal; run this script on that host):
    --local-data-path DIR   the Prometheus --storage.tsdb.path directory
  --data-path PATH          data directory inside the pod or container (default: read from
                            the Prometheus flag storage.tsdb.path, else /prometheus)

PROMETHEUS ACCESS (queries, verify)
  --prom-url URL            e.g. http://prometheus.monitoring:9090
  --prom-user U --prom-password P | --prom-token T      basic auth or Bearer token
  --prom-ca-cert FILE, --prom-insecure, --prom-header 'Name: value' (repeatable)
  --prom-path-prefix /prometheus    when Prometheus sits behind a path prefix
  --prom-version X.Y.Z      default: read from /api/v1/status/buildinfo
  --http-proxy URL, --no-proxy LIST   passed to curl and Python as the usual variables

TOOLS (all must already be installed; nothing is fetched)
  --python BIN  --curl BIN  --docker BIN  --kubectl BIN
  --promtool PATH           use this promtool. If not given: 'promtool' in PATH, else docker
                            with --promtool-image (default prom/prometheus:v<version>), but
                            only if that image is already on this host.
  --promtool-image IMAGE    full image reference, e.g. registry.example:5000/prom/prometheus:v3.5.0
  --pull                    allow 'docker pull' of that image (off by default)
  --docker-extra-args "..." extra arguments for the promtool 'docker run'
  --tool-dir DIR            folder with gah2prom.py, gitsync_to_dump.py, csv_to_dump.py
  --parallel N              promtool jobs at the same time (default 4)

LIMITS AND TIMING
  --reload-timeout S        wait this long for Prometheus to load the blocks (default 300)
  --reload-interval S       poll every S seconds (default 5)
  --min-free-disk-factor N  free space in the target must be at least N times the
                            estimated block size (default 4)
  --local-min-free-gb N     free local space must be at least N GB (default 5)
  --max-blocks N            refuse to copy more than N blocks (default 100)

CONTROL AND SAFETY
  --dry-run                 print every command, change nothing. Read-only checks are
                            tried; a failing check is only a warning.
  --plan                    like --dry-run, but the read-only checks against the real
                            target must pass, and sizes and block counts are printed
  --yes                     do not ask before the copy stage
  --confirm-string S        the target text, "<namespace>/<pod>" for k8s, "docker:<container>",
                            "local:<path>". Pass it to confirm without typing (also in
                            scripts). If it differs from the real target the run stops with
                            exit 10 and changes nothing. Without --yes and without it, an
                            interactive run asks you to type the target text, and a
                            non-interactive run stops with exit 10.
  --skip-verify             leave out the verify stage in --stage all
  --keep-om, --keep-blocks  keep the OpenMetrics files / local block copies
  --force-existing          continue although the target already has series with this source label
  --rollback                delete series {metric, source label} with the admin API, then
                            clean_tombstones (needs --web.enable-admin-api on Prometheus)
  --undo-blocks             remove only the block directories recorded in the undo list.
                            Safe only while compaction has not merged them yet.
  --undo-list FILE          default: <workdir>/undo-list.txt (written by the copy stage)
  --log-file FILE           default: <workdir>/migrate.log
  --no-color, --quiet       less output
  --print-config            show the resolved settings and stop
  --config FILE             read settings from FILE
  -h, --help                this text

EXIT CODES
   0  success (verify: PASS)
   1  verify found differences (FAIL), or an unexpected command failure
   2  wrong usage or settings (unknown option, missing value, bad config file)
   3  preflight failed (missing tool, target or Prometheus not usable, no space, series already exist)
   4  reading the history failed
   5  conversion to OpenMetrics failed
   6  building blocks with promtool failed
   7  copying blocks failed, or Prometheus did not load them in time
   9  rollback or undo-blocks failed
  10  not confirmed (answer was no, text did not match, or no confirmation possible)

EXAMPLES
  # 1. Practice cluster, history from a git checkout (all stages)
  KUBECONFIG=practice/kubeconfig tool/migrate.sh --source-type git \
    --history-repo ~/g-sync-test --from 2026-10-20 --prom-url http://127.0.0.1:29190 \
    --namespace monitoring --pod prometheus-0 --yes

  # 2. Production: live Grafana with a token, a read-only plan first
  export GRAFANA_TOKEN=... ; tool/migrate.sh --config prod.conf --plan
  # then the same command without --plan, and without --yes so it asks

  # 3. Resume one stage, check, and go back
  tool/migrate.sh --config prod.conf --stage verify
  tool/migrate.sh --config prod.conf --rollback
EOF
}

# ----------------------------------------------------------------------------
# small helpers
have() { command -v "$1" >/dev/null 2>&1; }

# dur_sec 1h30m -> seconds. Prints nothing and returns 1 on bad input.
dur_sec() {
    printf '%s\n' "$1" | awk '{
        s=$0; t=0
        if (s ~ /^[0-9]+$/) { print s; exit 0 }
        if (s !~ /^([0-9]+(ms|s|m|h|d|w|y))+$/) exit 1
        while (match(s, /^[0-9]+(ms|s|m|h|d|w|y)/)) {
            p=substr(s,1,RLENGTH); s=substr(s,RLENGTH+1)
            n=p; sub(/[a-z]+$/,"",n); u=p; sub(/^[0-9]+/,"",u)
            m=(u=="ms")?0.001:(u=="s")?1:(u=="m")?60:(u=="h")?3600:(u=="d")?86400:(u=="w")?604800:31536000
            t+=n*m
        }
        print t
    }'
}

# jx 'python expression over d' : read JSON on stdin, print the value (internal expressions only)
jx() {
    "$PYTHON" -c 'import sys, json
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1])
except Exception:
    sys.exit(1)
print("" if v is None else v)' "$1"
}

is_uint() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_ulid() { printf '%s\n' "$1" | grep -Eq '^[0-9A-HJKMNP-TV-Z]{26}$'; }
selector() { printf '%s{%s="%s"}' "$METRIC_NAME" "$SOURCE_LABEL_NAME" "$SOURCE_LABEL"; }
kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
tty_ok() { [ -t 0 ] && [ -t 2 ]; }

# read-only command: runs even in --dry-run, stdin closed, stderr kept in $SCRATCH/cap.err
cap() { "$@" </dev/null 2>"$SCRATCH/cap.err"; }
cap_err() { head -c 400 "$SCRATCH/cap.err" 2>/dev/null | tr '\n' ' '; }

# ----------------------------------------------------------------------------
# secrets: mask list, environment for the Python tools, curl config files
add_mask() {
    if [ "${#1}" -ge 3 ]; then
        case "$NL$MASKS$NL" in *"$NL$1$NL"*) ;; *) MASKS="$MASKS${MASKS:+$NL}$1" ;; esac
    fi
}
build_masks() {
    MASKS=
    for _mv in GRAFANA_TOKEN GRAFANA_PASSWORD PROM_PASSWORD PROM_TOKEN; do
        add_mask "$(getvar "$_mv")"
    done
    for _mv in GRAFANA_HEADER PROM_HEADER; do
        while IFS= read -r _h || [ -n "$_h" ]; do
            case $_h in *:*) trim "${_h#*:}"; add_mask "$TRIMMED" ;; esac
        done <<EOF
$(getvar "$_mv")
EOF
    done
}

exp_if() { # exp_if NAME VALUE: export when non-empty, else unset
    if [ -n "$2" ]; then setvar "$1" "$2"; export "$1"; else unset "$1" 2>/dev/null || true; fi
}
gah_export() {
    exp_if GAH_TOKEN "$GRAFANA_TOKEN"; exp_if GAH_USER "$GRAFANA_USER"; exp_if GAH_PASSWORD "$GRAFANA_PASSWORD"
    exp_if GAH_HEADERS "$GRAFANA_HEADER"
    exp_if GAH_PROM_TOKEN "$PROM_TOKEN"; exp_if GAH_PROM_USER "$PROM_USER"; exp_if GAH_PROM_PASSWORD "$PROM_PASSWORD"
    exp_if GAH_PROM_HEADERS "$PROM_HEADER"
}
gah_unset() {
    unset GAH_TOKEN GAH_USER GAH_PASSWORD GAH_HEADERS GAH_PROM_TOKEN GAH_PROM_USER GAH_PROM_PASSWORD GAH_PROM_HEADERS 2>/dev/null || true
}
# run a Python tool with the secrets in its environment (never on the command line)
pyrun() {
    gah_export
    _pr=0
    run "$@" || _pr=$?
    gah_unset
    return "$_pr"
}

cfg_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
# build_curl_cfg FILE USER PASSWORD TOKEN CA INSECURE HEADERS : curl -K file, mode 600
build_curl_cfg() {
    _cf=$1
    : > "$_cf"; chmod 600 "$_cf"
    if [ -n "$4" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$(cfg_esc "$4")" >> "$_cf"
    elif [ -n "$2" ]; then
        printf 'user = "%s"\n' "$(cfg_esc "$2:$3")" >> "$_cf"
    fi
    if [ -n "$5" ]; then printf 'cacert = "%s"\n' "$(cfg_esc "$5")" >> "$_cf"; fi
    if [ "$6" = 1 ]; then printf 'insecure\n' >> "$_cf"; fi
    while IFS= read -r _h || [ -n "$_h" ]; do
        [ -n "$_h" ] || continue
        printf 'header = "%s"\n' "$(cfg_esc "$_h")" >> "$_cf"
    done <<EOF
$7
EOF
}

# ----------------------------------------------------------------------------
# Prometheus access
pcurl() { # pcurl PATH [curl args...]  (body on stdout, fails on HTTP errors)
    _pp=$1; shift
    "$CURL" -sS -f --max-time 60 -K "$CURLCFG" "$@" "$PROM_BASE$_pp" </dev/null
}
pcurl_post() { # pcurl_post PATH [curl args...] -> prints the HTTP status; body in $SCRATCH/post.out
    _pp=$1; shift
    "$CURL" -sS --max-time 600 -K "$CURLCFG" -X POST -o "$SCRATCH/post.out" -w '%{http_code}' "$@" "$PROM_BASE$_pp" </dev/null
}
prom_scalar() {
    pcurl /api/v1/query -G --data-urlencode "query=$1" 2>/dev/null | jx 'd["data"]["result"][0]["value"][1]' || true
}
count_series() { # count_series SELECTOR : series in the whole TSDB
    _cn=$(date +%s)
    pcurl /api/v1/series -G --data-urlencode "match[]=$1" --data-urlencode "start=0" \
        --data-urlencode "end=$((_cn + 86400))" 2>/dev/null | jx 'len(d["data"])'
}

# read version and flags; sets PI_OK and F_*
prom_info() {
    PI_OK=0; PI_ERR=
    _bi=$(pcurl /api/v1/status/buildinfo 2>"$SCRATCH/pi.err") || { PI_ERR=$(head -c 300 "$SCRATCH/pi.err" | tr '\n' ' '); return 1; }
    F_VERSION=$(printf '%s' "$_bi" | jx 'd["data"]["version"]') || F_VERSION=
    _fl=$(pcurl /api/v1/status/flags 2>/dev/null) || _fl='{}'
    F_PATH=$(printf '%s' "$_fl" | jx 'd["data"].get("storage.tsdb.path","")') || F_PATH=
    F_RET_TIME=$(printf '%s' "$_fl" | jx 'd["data"].get("storage.tsdb.retention.time","")') || F_RET_TIME=
    F_RET_SIZE=$(printf '%s' "$_fl" | jx 'd["data"].get("storage.tsdb.retention.size","")') || F_RET_SIZE=
    F_LOOKBACK=$(printf '%s' "$_fl" | jx 'd["data"].get("query.lookback-delta","")') || F_LOOKBACK=
    F_ADMIN=$(printf '%s' "$_fl" | jx 'd["data"].get("web.enable-admin-api","")') || F_ADMIN=
    PI_OK=1
}

# ----------------------------------------------------------------------------
# environment for child processes (proxy, kubeconfig, tmpdir)
setup_child_env() {
    if [ -n "$KUBECONFIG" ]; then export KUBECONFIG; else unset KUBECONFIG 2>/dev/null || true; fi
    if [ -n "$HTTP_PROXY" ]; then
        http_proxy=$HTTP_PROXY; https_proxy=$HTTP_PROXY
        export HTTP_PROXY http_proxy https_proxy
        HTTPS_PROXY=$HTTP_PROXY; export HTTPS_PROXY
        NO_PROXY="${NO_PROXY:+$NO_PROXY,}127.0.0.1,localhost,::1"
        no_proxy=$NO_PROXY; export NO_PROXY no_proxy
    elif [ -n "$NO_PROXY" ]; then
        no_proxy=$NO_PROXY; export NO_PROXY no_proxy
    fi
}

# connect to Prometheus: port-forward if asked, curl config, info.
# ensure_prom required|optional ; sets PROM_READY=1 on success
ensure_prom() {
    [ "$PROM_READY" = 1 ] && return 0
    _need=$1
    if [ "$PORT_FORWARD" = 1 ]; then
        [ "$TARGET" = k8s ] || die $E_USAGE "--port-forward only works with --target k8s"
        [ -n "$PRIMARY" ] || resolve_units
        _pfp=$("$PYTHON" -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
        PROM_BASE="http://127.0.0.1:$_pfp$PROM_PATH_PREFIX"
        build_curl_cfg "$CURLCFG" "" "" "" "" 0 ""
        log INFO "port-forward: $PRIMARY:$POD_PORT -> 127.0.0.1:$_pfp"
        ( exec "$KUBECTL" ${KUBE_CONTEXT:+--context="$KUBE_CONTEXT"} ${NAMESPACE:+--namespace="$NAMESPACE"} \
            port-forward "pod/$PRIMARY" "$_pfp:$POD_PORT" ) >"$SCRATCH/pf.log" 2>&1 &
        PF_PID=$!
        _i=0
        while [ "$_i" -lt 30 ]; do
            if ! kill -0 "$PF_PID" 2>/dev/null; then
                PF_PID=
                fail_or_warn $E_PREFLIGHT "port-forward to $PRIMARY failed: $(head -c 300 "$SCRATCH/pf.log" | tr '\n' ' ')"
                return 1
            fi
            if pcurl /-/ready >/dev/null 2>&1; then break; fi
            _i=$((_i + 1)); sleep 1
        done
    else
        if [ -z "$PROM_URL" ]; then
            if [ "$_need" = required ]; then
                die $E_USAGE "no Prometheus address: set --prom-url (or --port-forward for a Kubernetes target)"
            fi
            return 1
        fi
        PROM_BASE="${PROM_URL%/}$PROM_PATH_PREFIX"
        build_curl_cfg "$CURLCFG" "$PROM_USER" "$PROM_PASSWORD" "$PROM_TOKEN" "$PROM_CA_CERT" "$PROM_INSECURE" "$PROM_HEADER"
    fi
    if prom_info; then
        PROM_READY=1
        [ -z "$PROM_VERSION" ] || F_VERSION=$PROM_VERSION
        log INFO "Prometheus $PROM_BASE: version ${F_VERSION:-unknown}, data path ${F_PATH:-unknown}, retention ${F_RET_TIME:-default}, lookback ${F_LOOKBACK:-default}"
        return 0
    fi
    if [ "$_need" = required ]; then
        fail_or_warn $E_PREFLIGHT "cannot reach Prometheus at $PROM_BASE (--prom-url): $PI_ERR"
    else
        log WARN "Prometheus not reachable at $PROM_BASE, using defaults (lookback 5m): $PI_ERR"
    fi
    return 1
}

# ----------------------------------------------------------------------------
# tools
need_tool() { # need_tool COMMAND --parameter
    case $1 in
        */*) [ -x "$1" ] && [ ! -d "$1" ] && return 0 ;;
        *) have "$1" && return 0 ;;
    esac
    fail_or_warn $E_PREFLIGHT "tool not found: '$1' (set --${2#--} or install it on this host; this script installs nothing)"
    return 1
}
tool_version() { # tool_version CMD args... : first line of the version output
    ( "$@" 2>&1 | head -n 1 ) </dev/null 2>/dev/null || true
}

# resolve_promtool: sets PT_MODE (bin|docker), PT_BIN or PT_IMG. Downloads nothing.
resolve_promtool() {
    PT_MODE=; PT_BIN=; PT_IMG=
    if [ -n "$PROMTOOL" ]; then
        case $PROMTOOL in
            */*) if [ -x "$PROMTOOL" ] && [ ! -d "$PROMTOOL" ]; then PT_BIN=$PROMTOOL; fi ;;
            *) if have "$PROMTOOL"; then PT_BIN=$(command -v "$PROMTOOL"); fi ;;
        esac
        if [ -z "$PT_BIN" ]; then
            fail_or_warn $E_PREFLIGHT "promtool not found at --promtool '$PROMTOOL'"
            return 1
        fi
    elif have promtool; then
        PT_BIN=$(command -v promtool)
    else
        if ! have "$DOCKER"; then
            fail_or_warn $E_PREFLIGHT "no promtool: not in PATH (--promtool PATH) and no docker ('$DOCKER', --docker) to run an image (--promtool-image)"
            return 1
        fi
        PT_IMG=$PROMTOOL_IMAGE
        if [ -z "$PT_IMG" ]; then
            if [ -n "${F_VERSION:-}" ]; then
                PT_IMG="prom/prometheus:v${F_VERSION#v}"
            else
                fail_or_warn $E_PREFLIGHT "no promtool in PATH; to use docker give --promtool-image (or --prom-version)"
                return 1
            fi
        fi
        if ! cap "$DOCKER" image inspect "$PT_IMG" >/dev/null; then
            if [ "$PULL" = 1 ]; then
                log INFO "image $PT_IMG not present, pulling because --pull was given"
                run "$DOCKER" pull "$PT_IMG" || { fail_or_warn $E_PREFLIGHT "docker pull $PT_IMG failed"; return 1; }
            else
                fail_or_warn $E_PREFLIGHT "promtool image not present locally: $PT_IMG (this script does not download; load it, or add --pull, or set --promtool / --promtool-image)"
                return 1
            fi
        fi
        PT_MODE=docker
        log INFO "promtool: docker image $PT_IMG"
        return 0
    fi
    PT_MODE=bin
    log INFO "promtool: $PT_BIN ($(tool_version "$PT_BIN" --version))"
}

# ----------------------------------------------------------------------------
# targets: k8s (kubectl/oc), docker, local
kc() { "$KUBECTL" ${KUBE_CONTEXT:+--context="$KUBE_CONTEXT"} ${NAMESPACE:+--namespace="$NAMESPACE"} "$@"; }

# t_sh UNIT SCRIPT [ARGS]: run  sh -c SCRIPT _ ARGS  inside the unit
t_sh() {
    _u=$1; _s=$2; shift 2
    case $TARGET in
        k8s) kc exec "$_u" -c "$CONTAINER" -- sh -c "$_s" _ "$@" ;;
        docker) _tr=0; set -f; "$DOCKER" exec $DOCKER_EXEC_ARGS "$_u" sh -c "$_s" _ "$@" || _tr=$?; set +f; return "$_tr" ;;
        local) sh -c "$_s" _ "$@" ;;
    esac
}
# same, with stdin passed through to the command
t_shi() {
    _u=$1; _s=$2; shift 2
    case $TARGET in
        k8s) kc exec -i "$_u" -c "$CONTAINER" -- sh -c "$_s" _ "$@" ;;
        docker) _tr=0; set -f; "$DOCKER" exec -i $DOCKER_EXEC_ARGS "$_u" sh -c "$_s" _ "$@" || _tr=$?; set +f; return "$_tr" ;;
        local) sh -c "$_s" _ "$@" ;;
    esac
}

target_string() {
    case $TARGET in
        k8s) printf '%s/%s' "$NAMESPACE" "$PRIMARY_NAME" ;;
        docker) printf 'docker:%s' "$DOCKER_CONTAINER" ;;
        local) printf 'local:%s' "$LOCAL_DATA_PATH" ;;
    esac
}

# resolve_units: UNITS (one per line), PRIMARY, PRIMARY_NAME. Checks they exist.
resolve_units() {
    [ -z "$PRIMARY" ] || return 0
    UNITS=
    case $TARGET in
        k8s)
            need_tool "$KUBECTL" --kubectl || return 1
            [ -n "$NAMESPACE" ] || die $E_USAGE "--namespace is required for --target k8s"
            if [ -n "$POD" ]; then UNITS=$POD; fi
            for _p in $REPLICAS; do UNITS="$UNITS${UNITS:+$NL}$_p"; done
            if [ -n "$SELECTOR" ]; then
                _sp=$(cap kc get pods -l "$SELECTOR" -o 'jsonpath={.items[*].metadata.name}') || \
                    { fail_or_warn $E_PREFLIGHT "cannot list pods with --selector '$SELECTOR' in namespace '$NAMESPACE': $(cap_err)"; return 1; }
                for _p in $_sp; do
                    case "$NL$UNITS$NL" in *"$NL$_p$NL"*) ;; *) UNITS="$UNITS${UNITS:+$NL}$_p" ;; esac
                done
            fi
            [ -n "$UNITS" ] || die $E_USAGE "no pod: set --pod or --selector for --target k8s"
            ;;
        docker)
            [ -n "$DOCKER_CONTAINER" ] || die $E_USAGE "--docker-container is required for --target docker"
            UNITS=$DOCKER_CONTAINER
            for _p in $REPLICAS; do UNITS="$UNITS$NL$_p"; done
            ;;
        local)
            [ -n "$LOCAL_DATA_PATH" ] || die $E_USAGE "--local-data-path is required for --target local"
            UNITS=local
            ;;
    esac
    PRIMARY=${UNITS%%"$NL"*}
    PRIMARY_NAME=$PRIMARY
    [ "$TARGET" != local ] || PRIMARY_NAME=$LOCAL_DATA_PATH
}

# verify every unit exists and is usable
check_units() {
    for _u in $UNITS; do
        case $TARGET in
            k8s)
                _ph=$(cap kc get pod "$_u" -o 'jsonpath={.status.phase}') || {
                    _all=$(cap kc get pods -o 'jsonpath={.items[*].metadata.name}' || true)
                    fail_or_warn $E_PREFLIGHT "pod '$_u' not found in namespace '$NAMESPACE' (--pod/--namespace). Pods there: ${_all:-none visible}"
                    return 1; }
                if [ "$_ph" != Running ]; then
                    fail_or_warn $E_PREFLIGHT "pod '$_u' is not Running (phase: $_ph)"; return 1
                fi
                _cs=$(cap kc get pod "$_u" -o 'jsonpath={.spec.containers[*].name}') || _cs=
                case " $_cs " in
                    *" $CONTAINER "*) ;;
                    *) fail_or_warn $E_PREFLIGHT "pod '$_u' has no container '$CONTAINER' (--container). Containers: $_cs"; return 1 ;;
                esac
                ;;
            docker)
                need_tool "$DOCKER" --docker || return 1
                _st=$(cap "$DOCKER" inspect -f '{{.State.Running}}' "$_u") || {
                    fail_or_warn $E_PREFLIGHT "docker container '$_u' not found (--docker-container)"; return 1; }
                [ "$_st" = true ] || { fail_or_warn $E_PREFLIGHT "docker container '$_u' is not running"; return 1; }
                ;;
            local)
                [ -d "$LOCAL_DATA_PATH" ] || { fail_or_warn $E_PREFLIGHT "--local-data-path '$LOCAL_DATA_PATH' is not a directory"; return 1; }
                ;;
        esac
    done
}

resolve_data_dir() {
    if [ "$TARGET" = local ]; then
        DATA_DIR=${LOCAL_DATA_PATH%/}
        [ -n "$DATA_DIR" ] || DATA_DIR=/
    elif [ -n "$DATA_PATH" ]; then
        DATA_DIR=${DATA_PATH%/}
    elif [ -n "$F_PATH" ]; then
        DATA_DIR=${F_PATH%/}
    else
        DATA_DIR=/prometheus
        log WARN "data directory not given (--data-path) and not readable from Prometheus flags; assuming $DATA_DIR"
    fi
    if [ "$TARGET" = local ] && [ -n "$F_PATH" ] && [ "${F_PATH%/}" != "$DATA_DIR" ]; then
        log WARN "Prometheus reports storage.tsdb.path=$F_PATH but --local-data-path is $DATA_DIR (a different mount path is normal behind a container)"
    fi
}

# check the data directory and tools in every unit; sets TOTAL_FREE_KB (smallest)
check_target() {
    resolve_data_dir
    MIN_FREE_KB=
    for _u in $UNITS; do
        _ls=$(cap t_sh "$_u" 'test -d "$1" || exit 41; test -w "$1" || exit 42; ls -A "$1"' "$DATA_DIR") || {
            _rc=$?
            case $_rc in
                41) fail_or_warn $E_PREFLIGHT "data directory '$DATA_DIR' does not exist in $_u (--data-path)" ;;
                42) fail_or_warn $E_PREFLIGHT "data directory '$DATA_DIR' is not writable in $_u (user/permissions; see --chown)" ;;
                *) fail_or_warn $E_PREFLIGHT "cannot run commands in $_u: $(cap_err)" ;;
            esac
            return 1; }
        _nb=0; _looks=0
        for _e in $_ls; do
            if is_ulid "$_e"; then _nb=$((_nb + 1)); _looks=1; fi
            case $_e in wal|chunks_head|lock|queries.active) _looks=1 ;; esac
        done
        if [ "$_looks" = 0 ]; then
            fail_or_warn $E_PREFLIGHT "'$DATA_DIR' in $_u does not look like a Prometheus data directory (no wal, chunks_head, lock or block directories)"
            return 1
        fi
        log INFO "target $_u: $DATA_DIR ok, $_nb existing block(s)"
        _tools='mv cat'
        [ "$COPY_METHOD" = cp ] && [ "$TARGET" = k8s ] && _tools='mv cat tar'
        [ "$COPY_METHOD" = exec-tar ] && _tools='mv cat tar'
        [ "$TARGET" != local ] || _tools='mv cat'
        for _t in $_tools; do
            cap t_sh "$_u" 'command -v "$1"' "$_t" >/dev/null || {
                fail_or_warn $E_PREFLIGHT "'$_t' is missing inside $_u, needed for --copy-method $COPY_METHOD (try --copy-method exec-cat)"
                return 1; }
        done
        _free=$(cap t_sh "$_u" 'df -Pk "$1" | awk "NR==2{print \$4}"' "$DATA_DIR") || _free=
        if is_uint "$_free"; then
            log INFO "target $_u: free space $((_free / 1024)) MB"
            if [ -z "$MIN_FREE_KB" ] || [ "$_free" -lt "$MIN_FREE_KB" ]; then MIN_FREE_KB=$_free; fi
        else
            log WARN "target $_u: free space unknown"
        fi
    done
}

# t_copy_block UNIT BLOCKDIR ULID : copy one block to DATA_DIR/ULID<suffix>
t_copy_block() {
    _u=$1; _src=$2; _name=$3$TMP_SUFFIX; _dst=$DATA_DIR/$_name
    case $TARGET in
        local) run cp -R "$_src" "$_dst" ;;
        docker)
            case $COPY_METHOD in
                cp) run "$DOCKER" cp "$_src" "$_u:$_dst" ;;
                exec-tar) copy_tar "$_u" "$_src" "$_dst" ;;
                exec-cat) copy_cat "$_u" "$_src" "$_dst" ;;
            esac ;;
        k8s)
            case $COPY_METHOD in
                cp) run kc cp "$_src" "$_u:$_dst" -c "$CONTAINER" ;;
                exec-tar) copy_tar "$_u" "$_src" "$_dst" ;;
                exec-cat) copy_cat "$_u" "$_src" "$_dst" ;;
            esac ;;
    esac
}
copy_tar() { # copy_tar UNIT SRC DST
    run t_sh "$1" 'mkdir -p "$1"' "$3" || return 1
    if [ "$DRY" = 1 ]; then log CMD "tar -C $2 -cf - . | <exec -i $1> tar -C $3 -xf -"; return 0; fi
    log CMD "tar -C $2 -cf - . | <exec -i $1> tar -C $3 -xf -"
    _tc=0
    ( cd "$2" && tar -cf - . ) | t_shi "$1" 'tar -C "$1" -xf -' "$3" >"$SCRATCH/tar.out" 2>&1 || _tc=$?
    if [ "$_tc" != 0 ]; then log ERROR "tar copy failed: $(head -c 300 "$SCRATCH/tar.out" | tr '\n' ' ')"; return 1; fi
}
copy_cat() { # copy_cat UNIT SRC DST : one 'cat >' per file, needs only sh and cat in the target
    run t_sh "$1" 'mkdir -p "$1/chunks"' "$3" || return 1
    if [ "$DRY" = 1 ]; then log CMD "for each file in $2: <exec -i $1> cat > $3/<file>"; return 0; fi
    _cl=$(cd "$2" && find . -type f | sed 's|^\./||')
    for _cfile in $_cl; do
        log DBG "cat $_cfile"
        run_i t_shi "$1" 'cat > "$1"' "$3/$_cfile" < "$2/$_cfile" || return 1
    done
}

# manifest "relative-path size" of a block, local and in the unit; must be identical
MANIFEST_SH='cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf "%s %s\n" "$f" "$(wc -c < "$f" | tr -d " ")"; done'
check_manifest() { # check_manifest UNIT SRC DST
    [ "$DRY" != 1 ] || return 0
    _ml=$(sh -c "$MANIFEST_SH" _ "$2")
    _mr=$(cap t_sh "$1" "$MANIFEST_SH" "$3") || { log ERROR "cannot read the copied block in $1: $(cap_err)"; return 1; }
    if [ "$_ml" != "$_mr" ]; then
        log ERROR "copied block differs from the local one in $1 ($3)"
        log ERROR "local:  $(printf '%s' "$_ml" | tr '\n' ';')"
        log ERROR "remote: $(printf '%s' "$_mr" | tr '\n' ';')"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# workdir, state, confirmation
MARKER_NAME=.migrate-workdir

init_workdir() {
    if [ "$DRY" = 1 ] && [ "$PLAN" != 1 ]; then
        [ -z "$LOG_FILE" ] || LOGF=$LOG_FILE
        return 0
    fi
    if [ -e "$WORKDIR" ] && [ ! -d "$WORKDIR" ]; then die $E_USAGE "--workdir '$WORKDIR' exists and is not a directory"; fi
    if [ -d "$WORKDIR" ] && [ ! -f "$WORKDIR/$MARKER_NAME" ] && [ -n "$(ls -A "$WORKDIR" 2>/dev/null)" ]; then
        die $E_USAGE "--workdir '$WORKDIR' is not empty and was not created by $PROG; use an empty or new directory"
    fi
    mkdir -p "$WORKDIR" || die $E_USAGE "cannot create --workdir '$WORKDIR'"
    if [ ! -f "$WORKDIR/$MARKER_NAME" ]; then
        printf 'created by %s; only the om and blocks folders inside are ever deleted\n' "$PROG" > "$WORKDIR/$MARKER_NAME"
    fi
    LOGF=${LOG_FILE:-$WORKDIR/migrate.log}
    STATE_FILE=$WORKDIR/state.env
}

# the only deletion in the workdir: $WORKDIR/om and $WORKDIR/blocks, in a workdir made by this script
rm_workdir_child() {
    case $1 in om|blocks) ;; *) die 1 "internal: refusing to delete '$1'" ;; esac
    [ -e "$WORKDIR/$1" ] || return 0
    if [ "$DRY" = 1 ]; then log CMD "rm -rf $WORKDIR/$1"; return 0; fi
    if [ -z "$WORKDIR" ] || [ "$WORKDIR" = / ] || [ ! -f "$WORKDIR/$MARKER_NAME" ]; then
        die 1 "internal: refusing to delete in '$WORKDIR' (not a workdir created by $PROG)"
    fi
    log CMD "rm -rf $WORKDIR/$1"
    rm -rf "${WORKDIR:?}/$1"
}

mark_done() {
    if [ "$DRY" != 1 ] && [ -n "$STATE_FILE" ]; then
        printf '%s=%s\n' "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STATE_FILE"
    fi
}

confirm_action() { # confirm_action "what will happen"
    if [ "$DRY" = 1 ]; then return 0; fi
    _want=$(target_string)
    if [ -n "$CONFIRM_STRING" ] && [ "$CONFIRM_STRING" != "$_want" ]; then
        die $E_ABORT "--confirm-string '$CONFIRM_STRING' does not match the real target '$_want'; nothing was changed"
    fi
    if [ "$YES" = 1 ]; then log INFO "confirmed by --yes: $1"; return 0; fi
    if [ -n "$CONFIRM_STRING" ]; then log INFO "confirmed by --confirm-string: $1"; return 0; fi
    if tty_ok; then
        log WARN "$1"
        printf 'Type %s to continue: ' "$_want" >&2
        _ans=
        read -r _ans || _ans=
        [ "$_ans" = "$_want" ] || die $E_ABORT "not confirmed (typed '$_ans'); nothing was changed"
    else
        die $E_ABORT "not confirmed: this is not an interactive terminal; pass --yes or --confirm-string '$_want'. Planned: $1"
    fi
}

# ----------------------------------------------------------------------------
# dump facts
dump_info() { # sets D_ANN D_RULES D_FROM D_TO
    [ -f "$DUMP_PATH" ] || return 1
    _di=$("$PYTHON" -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(len(d["annotations"]), len(d.get("rules", {})), d["from"], d["to"])' "$DUMP_PATH" 2>/dev/null) || return 1
    set -- $_di
    D_ANN=$1; D_RULES=$2; D_FROM=$3; D_TO=$4
}
ms_iso() { "$PYTHON" -c 'import sys, datetime
print(datetime.datetime.fromtimestamp(int(sys.argv[1]) / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }

# windows (= blocks) the history will need
estimate_blocks() { # -> BLOCK_EST
    BLOCK_EST=
    dump_info || return 1
    _w=$SPLIT
    [ "$_w" != none ] || _w=2h
    _ws=$(dur_sec "$_w")
    BLOCK_EST=$(awk -v f="$D_FROM" -v t="$D_TO" -v w="$_ws" 'BEGIN{w=w*1000; a=int(f/w); b=int(t/w); print b-a+1}')
}

check_step() {
    _ss=$(dur_sec "$STEP") || _ss=
    [ -n "$_ss" ] || die $E_USAGE "--step '$STEP' is not a duration like 15s or 1m"
    _lb=${F_LOOKBACK:-5m}
    _ls=$(dur_sec "$_lb") || _ls=300
    if awk -v a="$_ss" -v b="$_ls" 'BEGIN{exit !(a >= b)}'; then
        fail_or_warn $E_PREFLIGHT "--step $STEP is not below Prometheus' lookback delta ($_lb): instant queries would see gaps inside long intervals. Use a smaller --step."
        return 1
    fi
    log INFO "step $STEP is below the lookback delta $_lb"
}

check_retention() {
    _rt=$F_RET_TIME
    case $_rt in ''|0|0s) _rt= ;; esac
    if [ -z "$_rt" ]; then
        if [ -n "$F_RET_SIZE" ] && [ "$F_RET_SIZE" != 0 ]; then
            log INFO "retention: size based only ($F_RET_SIZE); old blocks can still be removed if the size limit is hit"
            return 0
        fi
        _rt=15d
    fi
    _from=
    if dump_info; then _from=$D_FROM
    elif [ -n "$FROM" ]; then
        _from=$("$PYTHON" -c 'import sys
sys.path.insert(0, sys.argv[1])
import gah2prom
print(gah2prom.parse_time(sys.argv[2]))' "$TOOL_DIR" "$FROM" 2>/dev/null) || _from=
    fi
    if [ -z "$_from" ]; then log INFO "retention: $_rt (history start unknown yet, checked again after the dump)"; return 0; fi
    _rs=$(dur_sec "$_rt") || _rs=
    [ -n "$_rs" ] || { log WARN "cannot read retention '$_rt'"; return 0; }
    if [ "$_from" -le 1000 ]; then _from=1000; fi
    if awk -v from="$_from" -v now="$(date +%s)" -v ret="$_rs" 'BEGIN{exit !((now - from / 1000) > ret)}'; then
        fail_or_warn $E_PREFLIGHT "history starts at $(ms_iso "$_from") which is older than Prometheus retention ($_rt). Prometheus counts retention from the newest block, so it would delete the imported blocks soon. Raise --storage.tsdb.retention.time on Prometheus or raise --from."
        return 1
    fi
    log INFO "history start $(ms_iso "$_from") is inside retention $_rt"
}

list_blocks() { # ULIDs in the local blocks folder, one per line
    [ -d "$WORKDIR/blocks" ] || return 0
    for _b in "$WORKDIR"/blocks/*; do
        [ -d "$_b" ] || continue
        _bn=${_b##*/}
        if is_ulid "$_bn"; then printf '%s\n' "$_bn"; fi
    done
}

# ----------------------------------------------------------------------------
# target preparation shared by several stages
TARGET_READY=0
setup_target() {
    [ "$TARGET_READY" = 0 ] || return 0
    resolve_units
    check_units
    check_target
    TARGET_READY=1
}

grafana_curl_cfg() {
    _gh=$GRAFANA_HEADER
    if [ -n "$ORG_ID" ]; then _gh="$_gh${_gh:+$NL}X-Grafana-Org-Id: $ORG_ID"; fi
    build_curl_cfg "$GCURLCFG" "$GRAFANA_USER" "$GRAFANA_PASSWORD" "$GRAFANA_TOKEN" "$GRAFANA_CA_CERT" "$INSECURE" "$_gh"
}

# ----------------------------------------------------------------------------
# stage: preflight
stage_preflight() {
    log INFO "== preflight =="
    need_tool "$PYTHON" --python || true
    if have "$PYTHON"; then
        "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null || \
            fail_or_warn $E_PREFLIGHT "$PYTHON is older than 3.8 (--python)"
        log INFO "python: $(tool_version "$PYTHON" --version)"
    fi
    need_tool "$CURL" --curl || true
    have "$CURL" && log INFO "curl: $(tool_version "$CURL" --version)"
    case $TARGET in
        k8s) need_tool "$KUBECTL" --kubectl || true
             have "$KUBECTL" && log INFO "kubectl: $(tool_version "$KUBECTL" version --client)" ;;
        docker) need_tool "$DOCKER" --docker || true ;;
    esac
    [ -f "$TOOL_DIR/gah2prom.py" ] || fail_or_warn $E_PREFLIGHT "gah2prom.py not found in --tool-dir '$TOOL_DIR'"
    # source
    case $SOURCE_TYPE in
        git)
            [ -f "$TOOL_DIR/gitsync_to_dump.py" ] || fail_or_warn $E_PREFLIGHT "gitsync_to_dump.py not found in --tool-dir '$TOOL_DIR'"
            _hd=${HISTORY_DIR:-$HISTORY_REPO/alert-history}
            if [ -d "$_hd" ]; then
                log INFO "source git: $_hd, $(find "$_hd" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ') day file(s)"
            else
                fail_or_warn $E_PREFLIGHT "alert history folder not found: $_hd (--history-repo / --history-dir)"
            fi ;;
        csv)
            [ -f "$TOOL_DIR/csv_to_dump.py" ] || fail_or_warn $E_PREFLIGHT "csv_to_dump.py not found in --tool-dir '$TOOL_DIR'"
            [ -r "$CSV" ] || fail_or_warn $E_PREFLIGHT "CSV file not readable: $CSV (--csv)" ;;
        dump)
            [ -f "$DUMP" ] || fail_or_warn $E_PREFLIGHT "dump file not found: $DUMP (--dump)" ;;
        grafana)
            grafana_curl_cfg
            _gu="${GRAFANA_URL%/}$GRAFANA_PATH_PREFIX"
            if cap "$CURL" -sS -f --max-time 30 -K "$GCURLCFG" "$_gu/api/health" >/dev/null; then
                if cap "$CURL" -sS -f --max-time 30 -K "$GCURLCFG" "$_gu/api/org" >/dev/null; then
                    log INFO "source grafana: $_gu reachable, credentials accepted"
                else
                    fail_or_warn $E_PREFLIGHT "Grafana $_gu answers but rejects the credentials (--token or --user/--password): $(cap_err)"
                fi
            else
                fail_or_warn $E_PREFLIGHT "cannot reach Grafana at $_gu (--grafana-url): $(cap_err)"
            fi ;;
    esac
    # Prometheus
    if ensure_prom required; then
        check_step
        check_retention
        if [ "$F_ADMIN" != true ]; then
            log WARN "Prometheus runs without --web.enable-admin-api: --rollback will not work (--undo-blocks still can)"
        fi
        _sel=$(selector)
        _ex=$(count_series "$_sel") || _ex=
        if is_uint "$_ex" && [ "$_ex" -gt 0 ]; then
            if [ "$FORCE_EXISTING" = 1 ]; then
                log WARN "$_ex series $_sel already exist; continuing because of --force-existing"
            else
                fail_or_warn $E_PREFLIGHT "$_ex series $_sel already exist in Prometheus. Importing again adds duplicate blocks. Run --rollback first, or add --force-existing."
            fi
        else
            log INFO "no existing series $_sel"
        fi
    fi
    # target
    setup_target || true
    # promtool
    case " $STAGE_LIST " in
        *" blocks "*) resolve_promtool || true ;;
    esac
    # local disk
    _p=$WORKDIR
    while [ ! -d "$_p" ] && [ "$_p" != / ]; do _p=${_p%/*}; [ -n "$_p" ] || _p=/; done
    _fk=$(df -Pk "$_p" 2>/dev/null | awk 'NR==2{print $4}')
    if is_uint "$_fk"; then
        log INFO "local free space at $_p: $((_fk / 1048576)) GB"
        if awk -v f="$_fk" -v m="$LOCAL_MIN_FREE_GB" 'BEGIN{exit !(f < m * 1048576)}'; then
            fail_or_warn $E_PREFLIGHT "less than $LOCAL_MIN_FREE_GB GB free for the work files at $_p (--workdir, --local-min-free-gb)"
        fi
    fi
    if estimate_blocks; then
        log INFO "dump: $D_ANN annotations, $D_RULES rules, $(ms_iso "$D_FROM") .. $(ms_iso "$D_TO"), about $BLOCK_EST block(s)"
        if [ "$BLOCK_EST" -gt "$MAX_BLOCKS" ]; then
            fail_or_warn $E_PREFLIGHT "about $BLOCK_EST blocks needed, more than --max-blocks $MAX_BLOCKS (raise --split or --max-blocks)"
        fi
    fi
    mark_done preflight
    log OK "preflight finished"
}

# ----------------------------------------------------------------------------
# stage: dump
stage_dump() {
    log INFO "== dump =="
    need_tool "$PYTHON" --python
    [ -n "$SOURCE_TYPE" ] || die $E_USAGE "--source-type is required for the dump stage"
    _save_dry=$DRY
    if [ "$PLAN" = 1 ]; then DRY=0; log INFO "plan: reading the source for real (read-only) to size the import"; fi
    case $SOURCE_TYPE in
        dump)
            DUMP_PATH=$DUMP
            [ -f "$DUMP_PATH" ] || fail_or_warn $E_DUMP "dump file not found: $DUMP_PATH"
            log INFO "using existing dump $DUMP_PATH" ;;
        git)
            [ -f "$TOOL_DIR/gitsync_to_dump.py" ] || die $E_PREFLIGHT "gitsync_to_dump.py not found in --tool-dir '$TOOL_DIR'"
            set -- "$PYTHON" "$TOOL_DIR/gitsync_to_dump.py" "$HISTORY_REPO" -o "$DUMP_PATH"
            [ -z "$HISTORY_DIR" ] || set -- "$@" --history-dir "$HISTORY_DIR"
            [ "$RULES_DIR" = '@default@' ] || set -- "$@" --rules-dir "$RULES_DIR"
            [ -z "$STATE" ] || set -- "$@" --state "$STATE"
            [ -z "$FROM" ] || set -- "$@" --from "$FROM"
            [ -z "$TO" ] || set -- "$@" --to "$TO"
            [ -z "$ORG_ID" ] || set -- "$@" --org-id "$ORG_ID"
            run "$@" || die $E_DUMP "reading the git history failed (see the lines above)" ;;
        csv)
            [ -f "$TOOL_DIR/csv_to_dump.py" ] || die $E_PREFLIGHT "csv_to_dump.py not found in --tool-dir '$TOOL_DIR'"
            set -- "$PYTHON" "$TOOL_DIR/csv_to_dump.py" "$CSV" --from "$CSV_FROM" --to "$CSV_TO" -o "$DUMP_PATH"
            [ -z "$ORG_ID" ] || set -- "$@" --org-id "$ORG_ID"
            run "$@" || die $E_DUMP "reading the CSV failed (see the lines above)" ;;
        grafana)
            set -- "$PYTHON" "$TOOL_DIR/gah2prom.py" export --url "${GRAFANA_URL%/}$GRAFANA_PATH_PREFIX" -o "$DUMP_PATH" --limit "$LIMIT"
            [ -z "$GRAFANA_CA_CERT" ] || set -- "$@" --ca-cert "$GRAFANA_CA_CERT"
            [ "$INSECURE" != 1 ] || set -- "$@" --insecure
            [ -z "$ORG_ID" ] || set -- "$@" --org-id "$ORG_ID"
            [ -z "$FROM" ] || set -- "$@" --from "$FROM"
            [ -z "$TO" ] || set -- "$@" --to "$TO"
            pyrun "$@" || die $E_DUMP "export from Grafana failed (see the lines above)" ;;
    esac
    DRY=$_save_dry
    if [ "$DRY" != 1 ] || [ "$PLAN" = 1 ]; then
        dump_info || die $E_DUMP "dump file missing or unreadable: $DUMP_PATH"
        log INFO "dump $DUMP_PATH: $D_ANN annotations, $D_RULES rules, $(ms_iso "$D_FROM") .. $(ms_iso "$D_TO")"
        [ "$D_ANN" -gt 0 ] || die $E_DUMP "the dump has 0 annotations: nothing to import (check --from/--to and the source)"
        check_retention || true
        if estimate_blocks; then log INFO "about $BLOCK_EST block(s) will be built"; fi
    fi
    mark_done dump
}

# ----------------------------------------------------------------------------
# stage: convert
stage_convert() {
    log INFO "== convert =="
    need_tool "$PYTHON" --python
    ensure_prom optional || true
    check_step
    if [ ! -f "$DUMP_PATH" ]; then
        if [ "$DRY" = 1 ]; then log WARN "dry-run: dump $DUMP_PATH does not exist yet"; else die $E_CONVERT "dump not found: $DUMP_PATH (run the dump stage first, or give --dump)"; fi
    fi
    rm_workdir_child om
    [ "$DRY" = 1 ] || mkdir -p "$WORKDIR/om"
    set -- "$PYTHON" "$TOOL_DIR/gah2prom.py" convert -i "$DUMP_PATH" --metric "$METRIC_NAME" \
        --source "$SOURCE_LABEL" --source-label "$SOURCE_LABEL_NAME" --step "$STEP" \
        --deleted-rule-end "$DELETED_RULE_END"
    if [ "$SPLIT" = none ]; then set -- "$@" -o "$WORKDIR/om/history.om"; else set -- "$@" --split "$SPLIT" -o "$WORKDIR/om"; fi
    while IFS= read -r _el || [ -n "$_el" ]; do
        [ -z "$_el" ] || set -- "$@" --extra-label "$_el"
    done <<EOF
$EXTRA_LABEL
EOF
    run "$@" || die $E_CONVERT "conversion failed (see the lines above)"
    if [ "$DRY" != 1 ]; then
        _n=0
        for _f in "$WORKDIR"/om/*.om; do [ -f "$_f" ] && _n=$((_n + 1)); done
        [ "$_n" -gt 0 ] || die $E_CONVERT "conversion wrote no .om file into $WORKDIR/om"
        log INFO "convert: $_n OpenMetrics file(s), $(( $(kb_of "$WORKDIR/om") / 1024 )) MB"
    fi
    mark_done convert
}

# ----------------------------------------------------------------------------
# stage: blocks
BLK_MD=
pt_exec() { # pt_exec FILE-NAME-IN-om : promtool for one file
    case $PT_MODE in
        bin) "$PT_BIN" tsdb create-blocks-from openmetrics ${BLK_MD:+--max-block-duration="$BLK_MD"} "$WORKDIR/om/$1" "$WORKDIR/blocks" ;;
        docker) _tr=0; set -f
            "$DOCKER" run --rm --user "$(id -u):$(id -g)" -v "$WORKDIR:/w" $DOCKER_EXTRA_ARGS --entrypoint promtool "$PT_IMG" \
                tsdb create-blocks-from openmetrics ${BLK_MD:+--max-block-duration="$BLK_MD"} "/w/om/$1" /w/blocks || _tr=$?
            set +f; return "$_tr" ;;
    esac
}
pt_cmd_text() {
    case $PT_MODE in
        bin) printf '%s tsdb create-blocks-from openmetrics %s %s %s' "$PT_BIN" "${BLK_MD:+--max-block-duration=$BLK_MD}" "$WORKDIR/om/$1" "$WORKDIR/blocks" ;;
        docker) printf '%s run --rm -v %s:/w %s --entrypoint promtool %s tsdb create-blocks-from openmetrics %s /w/om/%s /w/blocks' \
            "$DOCKER" "$WORKDIR" "$DOCKER_EXTRA_ARGS" "$PT_IMG" "${BLK_MD:+--max-block-duration=$BLK_MD}" "$1" ;;
    esac
}

stage_blocks() {
    log INFO "== blocks =="
    ensure_prom optional || true
    resolve_promtool || die $E_PREFLIGHT "no usable promtool"
    BLK_MD=$MAX_BLOCK_DURATION
    if [ -z "$BLK_MD" ] && [ "$SPLIT" != none ]; then BLK_MD=$SPLIT; fi
    _files=
    for _f in "$WORKDIR"/om/*.om; do
        [ -f "$_f" ] && _files="$_files${_files:+$NL}${_f##*/}"
    done
    if [ -z "$_files" ]; then
        if [ "$DRY" = 1 ]; then
            log WARN "dry-run: no OpenMetrics files yet; the command would run once per file in $WORKDIR/om"
            log CMD "$(pt_cmd_text '<file>.om')"
            return 0
        fi
        die $E_BLOCKS "no .om files in $WORKDIR/om (run the convert stage first)"
    fi
    rm_workdir_child blocks
    [ "$DRY" = 1 ] || mkdir -p "$WORKDIR/blocks"
    _i=0; _n=0; _pids=
    for _f in $_files; do
        _i=$((_i + 1))
        if [ "$DRY" = 1 ]; then log CMD "$(pt_cmd_text "$_f")"; continue; fi
        log INFO "promtool: $_f ($_i of $(printf '%s\n' "$_files" | wc -l | tr -d ' '))"
        ( _x=0; pt_exec "$_f" > "$SCRATCH/pt.$_i.out" 2>&1 || _x=$?; echo "$_x" > "$SCRATCH/pt.$_i.rc" ) &
        _pids="$_pids $!"; JOB_PIDS=$_pids
        _n=$((_n + 1))
        if [ "$_n" -ge "$PARALLEL" ]; then wait $_pids || true; _pids=; JOB_PIDS=; _n=0; fi
    done
    if [ -n "$_pids" ]; then wait $_pids || true; JOB_PIDS=; fi
    [ "$DRY" != 1 ] || return 0
    _bad=0; _k=0
    for _f in $_files; do
        _k=$((_k + 1))
        while IFS= read -r _l || [ -n "$_l" ]; do log OUT "promtool[$_k] $_l"; done < "$SCRATCH/pt.$_k.out"
        if [ "$(cat "$SCRATCH/pt.$_k.rc" 2>/dev/null || echo 1)" != 0 ]; then _bad=$((_bad + 1)); log ERROR "promtool failed for $_f"; fi
    done
    [ "$_bad" = 0 ] || die $E_BLOCKS "promtool failed for $_bad of $_i file(s)"
    _nb=$(list_blocks | wc -l | tr -d ' ')
    [ "$_nb" -gt 0 ] || die $E_BLOCKS "promtool made no block in $WORKDIR/blocks"
    log INFO "blocks: $_nb block(s), $(( $(kb_of "$WORKDIR/blocks") / 1024 )) MB"
    if [ "$KEEP_OM" != 1 ]; then rm_workdir_child om; else log INFO "keeping $WORKDIR/om (--keep-om)"; fi
    mark_done blocks
}

# ----------------------------------------------------------------------------
# stage: copy
scan_logs() { # warnings or errors Prometheus logged about blocks, last 15 minutes
    case $TARGET in
        k8s) _lg=$(cap kc logs "$PRIMARY" -c "$CONTAINER" --since=15m) || _lg= ;;
        docker) _lg=$("$DOCKER" logs --since 15m "$PRIMARY" 2>&1 </dev/null) || _lg= ;;
        *) log INFO "log check skipped (local target: look at Prometheus' own log)"; return 0 ;;
    esac
    _lw=$(printf '%s\n' "$_lg" | grep -iE 'level=(error|warn)' | grep -iE 'block|compact|reload|tsdb|retention|mmap' || true)
    if [ -n "$_lw" ]; then
        log WARN "Prometheus logged block related warnings or errors:"
        printf '%s\n' "$_lw" | head -n 5 | while IFS= read -r _x; do log WARN "  $_x"; done
    else
        log INFO "Prometheus log (15 min): no block, compaction or retention warnings"
    fi
}

copy_unit() { # copy_unit UNIT : copies all blocks, then renames them
    _cu=$1; _done=; _tmpl=
    for _b in $BLOCKS; do
        _have=$(cap t_sh "$_cu" 'test -e "$1/$2" && echo yes' "$DATA_DIR" "$_b") || _have=
        if [ "$_have" = yes ]; then log INFO "$_cu: block $_b already present, skipping"; continue; fi
        _tmp=$DATA_DIR/$_b$TMP_SUFFIX
        _left=$(cap t_sh "$_cu" 'test -e "$1" && echo yes' "$_tmp") || _left=
        if [ "$_left" = yes ]; then
            log WARN "$_cu: removing leftover temporary copy $_tmp from an earlier attempt"
            run t_sh "$_cu" 'rm -rf "$1"' "$_tmp" || return 1
        fi
        _tmpl="$_tmpl $_tmp"
        log INFO "$_cu: copying block $_b ($COPY_METHOD)"
        if ! t_copy_block "$_cu" "$WORKDIR/blocks/$_b" "$_b"; then
            log ERROR "$_cu: copy of $_b failed"; copy_cleanup "$_cu" "$_tmpl"; return 1
        fi
        if ! check_manifest "$_cu" "$WORKDIR/blocks/$_b" "$_tmp"; then copy_cleanup "$_cu" "$_tmpl"; return 1; fi
        if [ -n "$CHOWN" ]; then run t_sh "$_cu" 'chown -R "$2" "$1"' "$_tmp" "$CHOWN" || { copy_cleanup "$_cu" "$_tmpl"; return 1; }; fi
        if [ -n "$CHMOD" ]; then run t_sh "$_cu" 'chmod -R "$2" "$1"' "$_tmp" "$CHMOD" || { copy_cleanup "$_cu" "$_tmpl"; return 1; }; fi
        _done="$_done $_b"
    done
    # all copies are complete and identical: now make them visible, one atomic rename each
    for _b in $_done; do
        run t_sh "$_cu" 'mv "$1" "$2"' "$DATA_DIR/$_b$TMP_SUFFIX" "$DATA_DIR/$_b" || { log ERROR "$_cu: rename of $_b failed"; return 1; }
    done
    NEW_COUNT=$(printf '%s\n' $_done | grep -c . || true)
    log INFO "$_cu: $NEW_COUNT new block(s) in place"
}
# remove only the temporary copies this run made (names we generated: <ULID><suffix>)
copy_cleanup() {
    for _t in $2; do
        log WARN "$1: removing partial copy $_t"
        run t_sh "$1" 'rm -rf "$1"' "$_t" || true
    done
}

stage_copy() {
    log INFO "== copy =="
    ensure_prom required || true
    setup_target
    BLOCKS=$(list_blocks)
    if [ -z "$BLOCKS" ]; then
        if [ "$DRY" = 1 ]; then
            log WARN "dry-run: no blocks in $WORKDIR/blocks yet; showing the plan for $(target_string)"
            log CMD "per block: copy to $DATA_DIR/<ULID>$TMP_SUFFIX in $(printf '%s' "$UNITS" | tr '\n' ' ') with --copy-method $COPY_METHOD, compare file sizes, then mv to $DATA_DIR/<ULID>"
            return 0
        fi
        die $E_COPY "no blocks in $WORKDIR/blocks (run the blocks stage first)"
    fi
    _nb=$(printf '%s\n' "$BLOCKS" | wc -l | tr -d ' ')
    [ "$_nb" -le "$MAX_BLOCKS" ] || die $E_COPY "$_nb blocks is more than --max-blocks $MAX_BLOCKS; refusing to copy"
    _kb=$(kb_of "$WORKDIR/blocks"); is_uint "$_kb" || _kb=0
    log INFO "$_nb block(s), $((_kb / 1024)) MB to copy into: $(printf '%s' "$UNITS" | tr '\n' ' ')"
    if [ -n "$MIN_FREE_KB" ]; then
        if awk -v f="$MIN_FREE_KB" -v k="$_kb" -v n="$MIN_FREE_DISK_FACTOR" 'BEGIN{exit !(f < k * n)}'; then
            die $E_COPY "free space in the target ($((MIN_FREE_KB / 1024)) MB) is below $MIN_FREE_DISK_FACTOR times the blocks ($((_kb / 1024)) MB); see --min-free-disk-factor"
        fi
    fi
    if [ "$DRY" = 1 ]; then
        for _u in $UNITS; do for _b in $BLOCKS; do
            log CMD "[$_u] copy $WORKDIR/blocks/$_b -> $DATA_DIR/$_b$TMP_SUFFIX, compare sizes, mv to $DATA_DIR/$_b"
        done; done
        log INFO "dry-run: nothing copied"
        return 0
    fi
    confirm_action "copy $_nb block(s) ($((_kb / 1024)) MB) into $DATA_DIR of $(target_string)${REPLICAS:+ and replicas: $REPLICAS}; Prometheus will load them within about a minute"
    # undo list first, so an interrupted run can still be undone
    _ul=${UNDO_LIST:-$WORKDIR/undo-list.txt}
    if [ ! -f "$_ul" ]; then printf '# blocks added by %s; target %s; used by --undo-blocks\n' "$PROG" "$(target_string)" > "$_ul"; fi
    for _b in $BLOCKS; do
        grep -qx "$_b" "$_ul" 2>/dev/null || printf '%s\n' "$_b" >> "$_ul"
    done
    log INFO "undo list: $_ul"
    # baselines
    _b0=$(prom_scalar prometheus_tsdb_blocks_loaded)
    _r0=$(prom_scalar prometheus_tsdb_reloads_total)
    _f0=$(prom_scalar prometheus_tsdb_reloads_failures_total)
    _t0=$(prom_scalar prometheus_tsdb_time_retentions_total)
    _k0=$(prom_scalar prometheus_tsdb_compactions_total)
    _s0=$(count_series "$(selector)") || _s0=
    log INFO "before: blocks_loaded=${_b0:-?} reloads=${_r0:-?} reload_failures=${_f0:-?} retention_runs=${_t0:-?}"
    _prim_new=0
    for _u in $UNITS; do
        NEW_COUNT=0
        copy_unit "$_u" || die $E_COPY "copy into $_u failed; blocks already renamed in earlier targets are listed in $_ul (--undo-blocks)"
        [ "$_u" != "$PRIMARY" ] || _prim_new=$NEW_COUNT
    done
    if [ "$_prim_new" -eq 0 ]; then
        log INFO "no new blocks in the primary target; nothing to wait for"
        mark_done copy; return 0
    fi
    # wait until Prometheus has reloaded
    log INFO "waiting for Prometheus to load $_prim_new block(s) (up to ${RELOAD_TIMEOUT}s)"
    _t=0; _ok=0; _why=
    while [ "$_t" -le "$RELOAD_TIMEOUT" ]; do
        _b1=$(prom_scalar prometheus_tsdb_blocks_loaded)
        _r1=$(prom_scalar prometheus_tsdb_reloads_total)
        if is_uint "${_b0:-x}" && is_uint "${_b1:-x}" && [ "$_b1" -ge $((_b0 + _prim_new)) ]; then _ok=1; break; fi
        # Prometheus may merge the new block with overlapping ones right after loading it, so
        # blocks_loaded does not rise. A reload plus a compaction or new series also proves the load.
        if is_uint "${_r0:-x}" && is_uint "${_r1:-x}" && [ "$_r1" -gt "$_r0" ]; then
            _k1=$(prom_scalar prometheus_tsdb_compactions_total)
            _s1=$(count_series "$(selector)") || _s1=
            if is_uint "${_k0:-x}" && is_uint "${_k1:-x}" && [ "$_k1" -gt "$_k0" ]; then _ok=1; _why="compaction merged it with overlapping blocks"; break; fi
            if is_uint "${_s0:-x}" && is_uint "${_s1:-x}" && [ "$_s1" -gt "$_s0" ]; then _ok=1; _why="new series are visible"; break; fi
        fi
        sleep "$RELOAD_INTERVAL"; _t=$((_t + RELOAD_INTERVAL))
    done
    [ "$_ok" = 1 ] || die $E_COPY "Prometheus did not load the new block(s) within ${RELOAD_TIMEOUT}s (blocks_loaded ${_b0:-?} -> ${_b1:-?}); the blocks are in place, check Prometheus' log, then run the verify stage"
    log OK "Prometheus loaded the block(s) after about ${_t}s: blocks_loaded ${_b0:-?} -> ${_b1:-?}${_why:+ ($_why)}"
    for _b in $BLOCKS; do
        _still=$(cap t_sh "$PRIMARY" 'test -d "$1/$2" && echo yes' "$DATA_DIR" "$_b") || _still=
        if [ "$_still" != yes ]; then
            log WARN "block $_b is no longer a separate directory in $PRIMARY (merged by compaction). --undo-blocks cannot remove it any more; use --rollback."
        fi
    done
    _f1=$(prom_scalar prometheus_tsdb_reloads_failures_total)
    _t1=$(prom_scalar prometheus_tsdb_time_retentions_total)
    if is_uint "${_f0:-x}" && is_uint "${_f1:-x}" && [ "$_f1" -gt "$_f0" ]; then
        die $E_COPY "prometheus_tsdb_reloads_failures_total went up ($_f0 -> $_f1): Prometheus failed to reload; see its log"
    fi
    if is_uint "${_t0:-x}" && is_uint "${_t1:-x}" && [ "$_t1" -gt "$_t0" ]; then
        die $E_COPY "prometheus_tsdb_time_retentions_total went up ($_t0 -> $_t1): retention removed blocks; check the retention setting"
    fi
    scan_logs
    if [ -n "$REPLICAS" ] || [ "$(printf '%s\n' "$UNITS" | wc -l | tr -d ' ')" -gt 1 ]; then
        log WARN "only the primary ($PRIMARY) was checked through --prom-url; for the other replicas the block files were compared, loading was not checked"
    fi
    mark_done copy
}

# ----------------------------------------------------------------------------
# stage: verify
stage_verify() {
    log INFO "== verify =="
    need_tool "$PYTHON" --python
    ensure_prom required || true
    if [ ! -f "$DUMP_PATH" ]; then
        if [ "$DRY" = 1 ]; then log WARN "dry-run: dump $DUMP_PATH does not exist yet"; else die 1 "dump not found: $DUMP_PATH"; fi
    fi
    set -- "$PYTHON" "$TOOL_DIR/gah2prom.py" verify -i "$DUMP_PATH" --prometheus "$PROM_BASE" --metric "$METRIC_NAME" \
        --source "$SOURCE_LABEL" --source-label "$SOURCE_LABEL_NAME" --deleted-rule-end "$DELETED_RULE_END"
    [ "$PROM_INSECURE" != 1 ] || set -- "$@" --insecure
    [ -z "$PROM_CA_CERT" ] || set -- "$@" --ca-cert "$PROM_CA_CERT"
    while IFS= read -r _el || [ -n "$_el" ]; do
        [ -z "$_el" ] || set -- "$@" --extra-label "$_el"
    done <<EOF
$EXTRA_LABEL
EOF
    log CMD "$(quote_args "$@")"
    if [ "$DRY" = 1 ]; then return 0; fi
    _vo=$WORKDIR/verify-report.txt
    gah_export
    _vr=0
    "$@" > "$_vo" 2>&1 </dev/null || _vr=$?
    gah_unset
    while IFS= read -r _l || [ -n "$_l" ]; do log INFO "verify: $_l"; done < "$_vo"
    log INFO "full report: $_vo"
    if [ "$_vr" = 0 ]; then
        mark_done verify
        log PASS "verify PASS: every source transition is in Prometheus and nothing extra"
    else
        log FAIL "verify FAIL (exit $_vr): see the report above"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# stage: cleanup
stage_cleanup() {
    log INFO "== cleanup =="
    if [ "$KEEP_OM" = 1 ]; then log INFO "keeping om (--keep-om)"; else rm_workdir_child om; fi
    if [ "$KEEP_BLOCKS" = 1 ]; then log INFO "keeping blocks (--keep-blocks)"; else rm_workdir_child blocks; fi
    log INFO "kept: dump, log and undo list in $WORKDIR"
    mark_done cleanup
}

# ----------------------------------------------------------------------------
# rollback (admin API) and undo-blocks
stage_rollback() {
    log INFO "== rollback =="
    ensure_prom required || true
    _sel=$(selector)
    if [ "$PROM_READY" = 1 ] && [ "$F_ADMIN" != true ]; then
        fail_or_warn $E_ROLLBACK "Prometheus was not started with --web.enable-admin-api, the delete API is off. Use --undo-blocks while the blocks are still separate, or enable the flag."
    fi
    _c0=$(count_series "$_sel") || _c0=?
    log INFO "series $_sel before: $_c0"
    confirm_action "delete every series $_sel from Prometheus at $PROM_BASE (admin API delete_series + clean_tombstones)"
    log CMD "POST $PROM_BASE/api/v1/admin/tsdb/delete_series  match[]=$_sel"
    log CMD "POST $PROM_BASE/api/v1/admin/tsdb/clean_tombstones"
    if [ "$DRY" = 1 ]; then return 0; fi
    _hc=$(pcurl_post /api/v1/admin/tsdb/delete_series -G --data-urlencode "match[]=$_sel") || _hc=000
    [ "$_hc" = 204 ] || die $E_ROLLBACK "delete_series returned HTTP $_hc: $(head -c 300 "$SCRATCH/post.out" 2>/dev/null)"
    _hc=$(pcurl_post /api/v1/admin/tsdb/clean_tombstones) || _hc=000
    [ "$_hc" = 204 ] || die $E_ROLLBACK "clean_tombstones returned HTTP $_hc: $(head -c 300 "$SCRATCH/post.out" 2>/dev/null)"
    _c1=$(count_series "$_sel") || _c1=?
    log INFO "series $_sel after: $_c1"
    [ "$_c1" = 0 ] || die $E_ROLLBACK "$_c1 series still present after the delete"
    log OK "rollback done: no series $_sel left"
    mark_done rollback
}

stage_undo_blocks() {
    log INFO "== undo-blocks =="
    _ul=${UNDO_LIST:-$WORKDIR/undo-list.txt}
    [ -f "$_ul" ] || die $E_ROLLBACK "undo list not found: $_ul (--undo-list)"
    _ids=
    while IFS= read -r _l || [ -n "$_l" ]; do
        trim "$_l"; _l=$TRIMMED
        case $_l in ''|'#'*) continue ;; esac
        is_ulid "$_l" || die $E_ROLLBACK "$_ul: '$_l' is not a block name (ULID); refusing to continue"
        _ids="$_ids${_ids:+$NL}$_l"
    done < "$_ul"
    [ -n "$_ids" ] || die $E_ROLLBACK "undo list $_ul has no blocks"
    ensure_prom optional || true
    setup_target
    case $DATA_DIR in ''|/) die $E_ROLLBACK "unsafe data directory '$DATA_DIR'" ;; esac
    confirm_action "remove $(printf '%s\n' "$_ids" | wc -l | tr -d ' ') block directories listed in $_ul from $DATA_DIR of $(target_string)"
    _rm=0; _miss=0
    for _u in $UNITS; do
        for _b in $_ids; do
            _has=$(cap t_sh "$_u" 'test -d "$1/$2" && echo yes' "$DATA_DIR" "$_b") || _has=
            if [ "$_has" = yes ]; then
                run t_sh "$_u" 'rm -rf "$1/$2"' "$DATA_DIR" "$_b" || die $E_ROLLBACK "cannot remove $_b in $_u"
                _rm=$((_rm + 1))
            else
                _miss=$((_miss + 1)); log WARN "$_u: block $_b not found (already removed, or merged by compaction: then use --rollback)"
            fi
            _tmp=$DATA_DIR/$_b$TMP_SUFFIX
            _has=$(cap t_sh "$_u" 'test -e "$1" && echo yes' "$_tmp") || _has=
            if [ "$_has" = yes ]; then run t_sh "$_u" 'rm -rf "$1"' "$_tmp" || true; fi
        done
    done
    log OK "undo-blocks: removed $_rm block directory(ies), $_miss not found. Prometheus unloads them at its next reload (about a minute)."
    mark_done undo-blocks
}

# ----------------------------------------------------------------------------
# validation of the resolved settings
bad() { die $E_USAGE "$*"; }
validate_config() {
    case $TARGET in k8s|docker|local) ;; *) bad "--target must be k8s, docker or local (got '$TARGET')" ;; esac
    case $COPY_METHOD in cp|exec-tar|exec-cat) ;; *) bad "--copy-method must be cp, exec-tar or exec-cat (got '$COPY_METHOD')" ;; esac
    case $SOURCE_TYPE in ''|git|grafana|csv|dump) ;; *) bad "--source-type must be git, grafana, csv or dump (got '$SOURCE_TYPE')" ;; esac
    case $DELETED_RULE_END in last-event|export) ;; *) bad "--deleted-rule-end must be last-event or export" ;; esac
    [ -n "$(dur_sec "$STEP")" ] || bad "--step '$STEP' is not a duration like 15s or 1m"
    if [ "$SPLIT" != none ]; then [ -n "$(dur_sec "$SPLIT")" ] || bad "--split '$SPLIT' is not a duration like 486h (or 'none')"; fi
    if [ -n "$MAX_BLOCK_DURATION" ]; then
        [ -n "$(dur_sec "$MAX_BLOCK_DURATION")" ] || bad "--max-block-duration '$MAX_BLOCK_DURATION' is not a duration"
        if [ "$SPLIT" != none ] && [ "$(dur_sec "$MAX_BLOCK_DURATION")" != "$(dur_sec "$SPLIT")" ]; then
            bad "--max-block-duration ($MAX_BLOCK_DURATION) must equal --split ($SPLIT), or each file would not become exactly one block"
        fi
    fi
    for _nv in PARALLEL RELOAD_TIMEOUT RELOAD_INTERVAL MAX_BLOCKS POD_PORT LIMIT; do
        is_uint "$(getvar "$_nv")" || bad "${_nv} must be a whole number (got '$(getvar "$_nv")')"
    done
    [ "$PARALLEL" -ge 1 ] || bad "--parallel must be at least 1"
    [ "$RELOAD_INTERVAL" -ge 1 ] || bad "--reload-interval must be at least 1"
    printf '%s\n' "$MIN_FREE_DISK_FACTOR" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || bad "--min-free-disk-factor must be a number"
    printf '%s\n' "$LOCAL_MIN_FREE_GB" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || bad "--local-min-free-gb must be a number"
    printf '%s\n' "$TMP_SUFFIX" | grep -Eq '^\.[A-Za-z0-9._-]+$' || bad "--tmp-suffix must start with a dot and use only letters, digits, dot, dash, underscore"
    printf '%s\n' "$METRIC_NAME" | grep -Eq '^[A-Za-z_:][A-Za-z0-9_:]*$' || bad "--metric-name is not a valid metric name"
    printf '%s\n' "$SOURCE_LABEL_NAME" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || bad "--source-label-name is not a valid label name"
    case $SOURCE_LABEL in ''|*'"'*|*\\*) bad "--source-label must be non-empty and contain no quote or backslash" ;; esac
    if [ -n "$CHOWN" ]; then printf '%s\n' "$CHOWN" | grep -Eq '^[A-Za-z0-9._:-]+$' || bad "--chown must look like USER:GROUP or UID:GID"; fi
    if [ -n "$CHMOD" ]; then printf '%s\n' "$CHMOD" | grep -Eq '^([0-7]{3,4}|[ugoa]*[-+=][rwxXst]+(,[ugoa]*[-+=][rwxXst]+)*)$' || bad "--chmod must be a mode like 755 or u+rwX"; fi
    case $PROM_URL in ''|http://*|https://*) ;; *) bad "--prom-url must start with http:// or https://" ;; esac
    case $GRAFANA_URL in ''|http://*|https://*) ;; *) bad "--grafana-url must start with http:// or https://" ;; esac
    if [ "$PORT_FORWARD" = 1 ] && [ -n "$PROM_URL" ]; then bad "use either --prom-url or --port-forward, not both"; fi
    if [ "$PORT_FORWARD" = 1 ] && [ "$TARGET" != k8s ]; then bad "--port-forward needs --target k8s"; fi
    if [ -n "$PROM_TOKEN" ] && [ -n "$PROM_USER" ]; then bad "give either --prom-token or --prom-user/--prom-password, not both"; fi
    if [ -n "$GRAFANA_TOKEN" ] && [ -n "$GRAFANA_USER" ]; then bad "give either --token or --user/--password, not both"; fi
    if [ -n "$PROM_USER" ] && [ -z "$PROM_PASSWORD" ]; then bad "--prom-user needs --prom-password"; fi
    if [ -n "$GRAFANA_USER" ] && [ -z "$GRAFANA_PASSWORD" ]; then bad "--user needs --password"; fi
    for _hv in GRAFANA_HEADER PROM_HEADER; do
        while IFS= read -r _h || [ -n "$_h" ]; do
            [ -z "$_h" ] || case $_h in ?*:*) ;; *) bad "header '${_h%%:*}' must look like 'Name: value'" ;; esac
        done <<EOF
$(getvar "$_hv")
EOF
    done
    while IFS= read -r _el || [ -n "$_el" ]; do
        [ -z "$_el" ] || case $_el in ?*=*) ;; *) bad "--extra-label '$_el' must look like name=value" ;; esac
    done <<EOF
$EXTRA_LABEL
EOF
    if [ "$ROLLBACK" = 1 ] && [ "$UNDO_BLOCKS" = 1 ]; then bad "--rollback and --undo-blocks cannot be used together"; fi
    if { [ "$ROLLBACK" = 1 ] || [ "$UNDO_BLOCKS" = 1 ]; } && [ "$STAGE" != all ]; then bad "--stage cannot be combined with --rollback or --undo-blocks"; fi
}

# source specific required options, only for runs that include the dump stage
validate_source() {
    case $SOURCE_TYPE in
        git) [ -n "$HISTORY_REPO" ] || bad "--history-repo is required for --source-type git" ;;
        grafana) [ -n "$GRAFANA_URL" ] || bad "--grafana-url is required for --source-type grafana" ;;
        csv) [ -n "$CSV" ] && [ -n "$CSV_FROM" ] && [ -n "$CSV_TO" ] || bad "--csv, --csv-from and --csv-to are required for --source-type csv"
             is_uint "$CSV_FROM" && is_uint "$CSV_TO" || bad "--csv-from and --csv-to are epoch milliseconds" ;;
        dump) [ -n "$DUMP" ] || bad "--dump FILE is required for --source-type dump" ;;
        '') bad "--source-type is required (git, grafana, csv or dump)" ;;
    esac
}

expand_stages() {
    STAGE_LIST=
    if [ "$ROLLBACK" = 1 ]; then STAGE_LIST=rollback; return 0; fi
    if [ "$UNDO_BLOCKS" = 1 ]; then STAGE_LIST=undo-blocks; return 0; fi
    _sl=$(printf '%s' "$STAGE" | tr ',' ' ')
    for _s in $_sl; do
        case $_s in
            all)
                for _a in preflight dump convert blocks copy verify cleanup; do
                    if [ "$_a" = verify ] && [ "$SKIP_VERIFY" = 1 ]; then continue; fi
                    STAGE_LIST="$STAGE_LIST $_a"
                done ;;
            preflight|dump|convert|blocks|copy|verify|cleanup|rollback|undo-blocks) STAGE_LIST="$STAGE_LIST $_s" ;;
            *) bad "unknown stage '$_s' (preflight dump convert blocks copy verify cleanup all rollback undo-blocks)" ;;
        esac
    done
    STAGE_LIST=${STAGE_LIST# }
    [ -n "$STAGE_LIST" ] || bad "--stage is empty"
}

# ----------------------------------------------------------------------------
cleanup_exit() {
    _ec=$?
    trap - EXIT INT TERM HUP
    if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi
    for _jp in $JOB_PIDS; do kill "$_jp" 2>/dev/null || true; done
    case $SCRATCH in
        */migrate.??????*) rm -rf "$SCRATCH" ;;
    esac
    exit "$_ec"
}

main() {
    snapshot_env
    apply_defaults
    prescan "$@"
    _cfg=$CFG_CLI
    if [ -z "$_cfg" ] && [ "$(getvar ENVS_CONFIG)" = 1 ]; then _cfg=$(getvar ENVV_CONFIG); fi
    if [ -n "$_cfg" ]; then parse_config "$_cfg"; CONFIG=$_cfg; SRC_CONFIG=${CFG_CLI:+cli}; SRC_CONFIG=${SRC_CONFIG:-env}; fi
    apply_env
    parse_args "$@"
    [ -z "$CFG_CLI" ] || { CONFIG=$CFG_CLI; SRC_CONFIG=cli; }

    [ "$NO_COLOR" = 0 ] && [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] && COLOR=1
    DRY=$DRY_RUN
    [ "$PLAN" != 1 ] || DRY=1
    [ -n "$TOOL_DIR" ] || TOOL_DIR=$SELF_DIR
    TOOL_DIR=${TOOL_DIR%/}
    case $WORKDIR in /*) ;; *) WORKDIR=$PWD/${WORKDIR#./} ;; esac
    WORKDIR=${WORKDIR%/}
    [ -n "$WORKDIR" ] || bad "--workdir must not be empty or /"
    [ -n "$TMPDIR" ] || TMPDIR=/tmp
    TMPDIR=${TMPDIR%/}
    case $UNDO_LIST in ''|/*) ;; *) UNDO_LIST=$PWD/$UNDO_LIST ;; esac
    case $LOG_FILE in ''|/*) ;; *) LOG_FILE=$PWD/$LOG_FILE ;; esac

    validate_config
    expand_stages
    build_masks
    SCRATCH=$(mktemp -d "$TMPDIR/migrate.XXXXXX") || bad "cannot create a temporary folder in --tmpdir '$TMPDIR'"
    chmod 700 "$SCRATCH"
    CURLCFG=$SCRATCH/curl.cfg; GCURLCFG=$SCRATCH/gcurl.cfg
    trap cleanup_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    setup_child_env

    if [ "$PRINT_CONFIG" = 1 ]; then
        log INFO "stages: $STAGE_LIST"
        print_config
        exit 0
    fi

    case " $STAGE_LIST " in *" dump "*) validate_source ;; esac
    init_workdir
    DUMP_PATH=$WORKDIR/dump.json
    if [ -n "$DUMP" ]; then
        if [ "$SOURCE_TYPE" = dump ] || [ -z "$SOURCE_TYPE" ]; then DUMP_PATH=$DUMP; fi
    fi
    if [ -n "$DUMP" ] && [ -n "$SOURCE_TYPE" ] && [ "$SOURCE_TYPE" != dump ]; then
        log WARN "--dump is ignored for --source-type $SOURCE_TYPE (the dump is written to $DUMP_PATH)"
    fi
    log INFO "$PROG start, stages: $STAGE_LIST"
    if [ "$PLAN" = 1 ]; then log INFO "PLAN mode: read-only checks are real, nothing is changed in the target"
    elif [ "$DRY" = 1 ]; then log INFO "DRY-RUN: commands are only printed; read-only checks are tried, failures are warnings"; fi
    print_config

    for _st in $STAGE_LIST; do
        case $_st in
            preflight) stage_preflight ;;
            dump) stage_dump ;;
            convert) stage_convert ;;
            blocks) stage_blocks ;;
            copy) stage_copy ;;
            verify) stage_verify ;;
            cleanup) stage_cleanup ;;
            rollback) stage_rollback ;;
            undo-blocks) stage_undo_blocks ;;
        esac
    done
    log OK "finished: $STAGE_LIST"
}

main "$@"
