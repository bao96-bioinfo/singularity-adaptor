#!/usr/bin/env bash
# =============================================================================================
# start_singularity.sh — one launcher for the cell_eval Apptainer/Singularity image.
#
#   shell    interactive login shell inside the image on this machine (or a compute node)
#   exec     run one command inside the image              (start_singularity.sh exec ... -- cmd args)
#   jupyter  JupyterLab inside the image + the ssh-tunnel command and URL for your laptop
#   claude   Claude Code inside the image                  (start_singularity.sh claude ... -- --continue)
#   sbatch   submit jupyter / claude / exec as a SLURM job  (start_singularity.sh sbatch jupyter ...)
#   srun     interactive SLURM allocation running shell/jupyter/claude/exec (srun --pty)
#   connect  print the tunnel command and URL of a running jupyter session (login node)
#   check    pre-flight + smoke test only
#
# Nothing is hard-coded: the image defaults to cell_eval.sif next to this script, the working
# directory to the current directory, and the scratch directory must be given (--scratch).
# Inside the container:  --workdir -> /workspace   --scratch -> /scratch   HOME -> a private
# temporary HOME with the state directories of claude / codex / antigravity and your ssh / git
# configuration bound into it, so logins and chat history persist and nothing else leaks in.
# Host tools (SLURM clients + munge, ssh, gh, claude, codex, agy, any --host-tool) are located with `command -v`,
# bound read-only, and the shared libraries they need that the image lacks are staged and added to
# LD_LIBRARY_PATH. uv, Node.js and openspec are part of the image; the launcher installs nothing.
# Run with no arguments for help.
# =============================================================================================
# shellcheck disable=SC2088   # '~/...' below are display strings, not paths
set -Eeuo pipefail
ORIG_UMASK="$(umask)"      # the user's own policy: applied inside the container and to the scratch-side folders
umask 077                   # the launcher's private files (temporary HOME, session files)

SCRIPT_VERSION="2026-10-07"
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "${SELF}")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-cell_eval}"

# --------------------------------------------------------------------------------------------
# Help
# --------------------------------------------------------------------------------------------
usage() {
    cat <<'HELP_EOF'
start_singularity.sh — launcher for the cell_eval image (shell, Jupyter, Claude Code, SLURM)

USAGE
  bash start_singularity.sh <mode> [options] [-- command ...]

MODES
  shell                 interactive login shell in /workspace (needs a terminal)
  exec -- CMD [ARGS]    run CMD inside the image, then exit
  jupyter               start JupyterLab here; prints the ssh tunnel command + URL, writes a session file
  claude [-- ARGS]      start Claude Code inside the image (ARGS are passed to `claude`)
  sbatch <jupyter|claude|exec> [options] [-- CMD]
                        submit that mode as a SLURM job (resources below are REQUIRED)
  srun   <shell|jupyter|claude|exec> [options] [-- CMD]
                        interactive SLURM allocation (srun --pty) running that mode
  connect [JOBID]       show tunnel command + URL of the newest (or given) jupyter session
  check                 pre-flight checks + smoke test, then exit
  help                  this text

REQUIRED
  --scratch DIR         scratch directory, mounted at /scratch           [env SCRATCH_DIR]

PATHS
  --workdir DIR         project/working directory, mounted at /workspace  [env WORKDIR, default: current dir]
  --image FILE          the .sif image                                    [env IMAGE, default: cell_eval.sif next to this script]
  --notebook-dir DIR    JupyterLab root (container or host path)           [default: /workspace]
  --bind SRC[:DST[:ro]] extra bind mount (repeatable)
  --env KEY=VALUE       extra environment variable inside the container (repeatable)

GPU / CHECKS
  --gpu | --no-gpu      force GPU passthrough (--nv) on/off                 [default: on when nvidia-smi sees a GPU]
  --cuda-devices LIST   CUDA_VISIBLE_DEVICES inside, e.g. 0 or 2,3 (shared multi-GPU nodes; SLURM sets it for jobs)
  --no-smoke            skip the import/CUDA smoke test at start
  --dry-run             print the container command instead of running it
  --verbose             show every bind and staged library

HOST TOOLS (each bound when found on the host; disable individually)
  --no-slurm            do not bind sbatch/squeue/scancel/sinfo/srun/scontrol/sacct/sacctmgr + slurm.conf + munge
  --no-ssh              do not bind ssh, /etc/ssh, ~/.ssh (ro), ~/.gitconfig, gh
  --no-claude           do not bind the claude binary and ~/.claude, ~/.claude.json
  --no-codex            do not bind codex / agy / antigravity and ~/.codex, ~/.gemini
  --host-tool NAME      bind another host executable (or Node.js script, run with the image's node) into the container (repeatable)
  --engine NAME         apptainer or singularity                           [env CONTAINER_ENGINE, default: first found]

JUPYTER
  --port N              listening port on the compute node                 [default: a free port in 8000-8999]
  --login-host HOST     login node used in the ssh tunnel command          [env LOGIN_HOST; sbatch: the submitting host]
  --jupyter-arg ARG     extra argument for `jupyter lab` (repeatable)

SLURM (sbatch / srun modes; no built-in defaults — every resource must be given or exported)
  --partition P         [env SLURM_PARTITION]        --time HH:MM:SS   [env SLURM_TIME]
  --cpus N              [env SLURM_CPUS]             --mem SIZE        [env SLURM_MEM]   e.g. 64G
  --gpus N              [env SLURM_GPUS]  optional   --account A       [env SLURM_ACCOUNT] optional
  --job-name NAME       [default: cell_eval-<mode>]  --log-dir DIR     [default: <scratch>/.start_singularity/slurm_logs]
  --sbatch-arg ARG      extra argument for sbatch/srun (repeatable), e.g. --sbatch-arg=--constraint=a100

EXAMPLES
  # interactive shell on the node you are logged into (GPU if present)
  bash start_singularity.sh shell --scratch /allen/.../scratch/$USER

  # JupyterLab on a compute node, then follow the printed instructions (or run `connect` later)
  bash start_singularity.sh sbatch jupyter --workdir /allen/.../261005-Evaluation --scratch /allen/.../scratch/$USER \
       --partition celltypes --time 08:00:00 --cpus 8 --mem 64G --gpus 1 --login-host hpc.corp.alleninstitute.org
  bash start_singularity.sh connect

  # headless notebook run as a batch job
  bash start_singularity.sh sbatch exec --scratch ... --partition ... --time 04:00:00 --cpus 8 --mem 64G --gpus 1 \
       -- papermill evaluation_metrics_science_revision.ipynb /scratch/executed.ipynb

  # Claude Code on a compute node, reachable from your laptop with `claude --remote-control`
  bash start_singularity.sh sbatch claude --scratch ... --partition ... --time 48:00:00 --cpus 4 --mem 32G \
       -- --continue --remote-control

  # interactive allocation with a shell
  bash start_singularity.sh srun shell --scratch ... --partition ... --time 02:00:00 --cpus 4 --mem 32G --gpus 1

INSIDE THE CONTAINER
  /workspace = --workdir   /scratch = --scratch   python = /opt/venv/bin/python (torch 2.9.1 + CUDA 12.8, scvi-tools 1.4.2)
  uv, node and openspec are in the image (uv caches and `uv tool` installs persist under /scratch/.start_singularity/uv)
  CELL_TOOLS_REPO and LUNG_ATLAS_H5AD are set automatically when <workdir>/capsule-3642729/{cell_tools,data/lung_atlas.h5ad} exist.
HELP_EOF
}

# --------------------------------------------------------------------------------------------
# Messages
# --------------------------------------------------------------------------------------------
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }
warn()  { printf 'WARN:  %s\n' "$*" >&2; }
info()  { printf '%s\n' "$*"; }
debug() { [[ "${VERBOSE}" == 1 ]] && printf 'debug: %s\n' "$*" >&2 || true; }

abspath() {   # absolute, symlink-free path of an existing file or directory
    local p="$1"
    if [[ -d "${p}" ]]; then (cd "${p}" && pwd -P)
    else printf '%s/%s\n' "$(cd "$(dirname "${p}")" && pwd -P)" "$(basename "${p}")"
    fi
}

# --------------------------------------------------------------------------------------------
# Defaults (environment variables), then the command line
# --------------------------------------------------------------------------------------------
MODE=""
SUBMODE=""                       # inner mode for sbatch / srun
IMAGE="${IMAGE:-}"
WORKDIR="${WORKDIR:-}"
SCRATCH_DIR="${SCRATCH_DIR:-}"
NOTEBOOK_DIR="${NOTEBOOK_DIR:-/workspace}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"
USE_GPU="${USE_GPU:-auto}"       # auto | 1 | 0
CUDA_DEVICES="${CUDA_DEVICES:-}"
RUN_SMOKE=1
DRY_RUN=0
VERBOSE=0
BIND_SLURM=1; BIND_SSH=1; BIND_CLAUDE=1; BIND_CODEX=1
HOST_TOOLS=()
JUPYTER_PORT="${JUPYTER_PORT:-}"
LOGIN_HOST="${LOGIN_HOST:-}"
SLURM_PARTITION="${SLURM_PARTITION:-}"
SLURM_TIME="${SLURM_TIME:-}"
SLURM_CPUS="${SLURM_CPUS:-}"
SLURM_MEM="${SLURM_MEM:-}"
SLURM_GPUS="${SLURM_GPUS:-}"
SLURM_ACCOUNT="${SLURM_ACCOUNT:-}"
SLURM_JOB_NAME_OPT=""
SLURM_LOG_DIR=""
EXTRA_BINDS=()
EXTRA_ENVS=()
JUPYTER_ARGS=()
SBATCH_ARGS=()
CMD=()
CONNECT_JOB=""

[[ $# -gt 0 ]] || { usage; exit 0; }
MODE="$1"; shift
case "${MODE}" in
    -h|--help|help) usage; exit 0 ;;
    shell|exec|jupyter|claude|check|connect) ;;
    sbatch|srun)
        [[ $# -gt 0 ]] || fatal "${MODE} needs an inner mode: ${MODE} <jupyter|claude|exec$([[ ${MODE} == srun ]] && printf '|shell')>"
        SUBMODE="$1"; shift
        case "${MODE}:${SUBMODE}" in
            sbatch:jupyter|sbatch:claude|sbatch:exec|srun:shell|srun:jupyter|srun:claude|srun:exec) ;;
            sbatch:shell) fatal "a batch job has no terminal; use 'srun shell' for an interactive allocation" ;;
            *) fatal "unknown inner mode '${SUBMODE}' for ${MODE}" ;;
        esac ;;
    -*) fatal "the first argument must be a mode (shell, exec, jupyter, claude, sbatch, srun, connect, check); run without arguments for help" ;;
    *)  fatal "unknown mode '${MODE}'; run without arguments for help" ;;
esac

need_val() { [[ $# -ge 2 && -n "${2:-}" ]] || fatal "option $1 needs a value"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scratch)        need_val "$@"; SCRATCH_DIR="$2"; shift 2 ;;
        --scratch=*)      SCRATCH_DIR="${1#*=}"; shift ;;
        --workdir)        need_val "$@"; WORKDIR="$2"; shift 2 ;;
        --workdir=*)      WORKDIR="${1#*=}"; shift ;;
        --image)          need_val "$@"; IMAGE="$2"; shift 2 ;;
        --image=*)        IMAGE="${1#*=}"; shift ;;
        --notebook-dir)   need_val "$@"; NOTEBOOK_DIR="$2"; shift 2 ;;
        --notebook-dir=*) NOTEBOOK_DIR="${1#*=}"; shift ;;
        --bind)           need_val "$@"; EXTRA_BINDS+=("$2"); shift 2 ;;
        --bind=*)         EXTRA_BINDS+=("${1#*=}"); shift ;;
        --env)            need_val "$@"; EXTRA_ENVS+=("$2"); shift 2 ;;
        --env=*)          EXTRA_ENVS+=("${1#*=}"); shift ;;
        --cuda-devices)   need_val "$@"; CUDA_DEVICES="$2"; shift 2 ;;
        --cuda-devices=*) CUDA_DEVICES="${1#*=}"; shift ;;
        --gpu)            USE_GPU=1; shift ;;
        --no-gpu)         USE_GPU=0; shift ;;
        --no-smoke)       RUN_SMOKE=0; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --verbose|-v)     VERBOSE=1; shift ;;
        --no-slurm)       BIND_SLURM=0; shift ;;
        --no-ssh)         BIND_SSH=0; shift ;;
        --no-claude)      BIND_CLAUDE=0; shift ;;
        --no-codex)       BIND_CODEX=0; shift ;;
        --host-tool)      need_val "$@"; HOST_TOOLS+=("$2"); shift 2 ;;
        --host-tool=*)    HOST_TOOLS+=("${1#*=}"); shift ;;
        --engine)         need_val "$@"; CONTAINER_ENGINE="$2"; shift 2 ;;
        --engine=*)       CONTAINER_ENGINE="${1#*=}"; shift ;;
        --port)           need_val "$@"; JUPYTER_PORT="$2"; shift 2 ;;
        --port=*)         JUPYTER_PORT="${1#*=}"; shift ;;
        --login-host)     need_val "$@"; LOGIN_HOST="$2"; shift 2 ;;
        --login-host=*)   LOGIN_HOST="${1#*=}"; shift ;;
        --jupyter-arg)    need_val "$@"; JUPYTER_ARGS+=("$2"); shift 2 ;;
        --jupyter-arg=*)  JUPYTER_ARGS+=("${1#*=}"); shift ;;
        --partition)      need_val "$@"; SLURM_PARTITION="$2"; shift 2 ;;
        --partition=*)    SLURM_PARTITION="${1#*=}"; shift ;;
        --time)           need_val "$@"; SLURM_TIME="$2"; shift 2 ;;
        --time=*)         SLURM_TIME="${1#*=}"; shift ;;
        --cpus)           need_val "$@"; SLURM_CPUS="$2"; shift 2 ;;
        --cpus=*)         SLURM_CPUS="${1#*=}"; shift ;;
        --mem)            need_val "$@"; SLURM_MEM="$2"; shift 2 ;;
        --mem=*)          SLURM_MEM="${1#*=}"; shift ;;
        --gpus)           need_val "$@"; SLURM_GPUS="$2"; shift 2 ;;
        --gpus=*)         SLURM_GPUS="${1#*=}"; shift ;;
        --account)        need_val "$@"; SLURM_ACCOUNT="$2"; shift 2 ;;
        --account=*)      SLURM_ACCOUNT="${1#*=}"; shift ;;
        --job-name)       need_val "$@"; SLURM_JOB_NAME_OPT="$2"; shift 2 ;;
        --job-name=*)     SLURM_JOB_NAME_OPT="${1#*=}"; shift ;;
        --log-dir)        need_val "$@"; SLURM_LOG_DIR="$2"; shift 2 ;;
        --log-dir=*)      SLURM_LOG_DIR="${1#*=}"; shift ;;
        --sbatch-arg)     need_val "$@"; SBATCH_ARGS+=("$2"); shift 2 ;;
        --sbatch-arg=*)   SBATCH_ARGS+=("${1#*=}"); shift ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; CMD=("$@"); break ;;
        -*)               fatal "unknown option: $1 (run without arguments for help)" ;;
        *)
            if [[ "${MODE}" == connect && -z "${CONNECT_JOB}" ]]; then CONNECT_JOB="$1"; shift
            else fatal "unexpected argument: $1 (put a command after '--')"
            fi ;;
    esac
done

case "${MODE}:${SUBMODE}" in
    exec:|sbatch:exec|srun:exec) [[ ${#CMD[@]} -gt 0 ]] || fatal "exec needs a command after '--'" ;;
esac

# --------------------------------------------------------------------------------------------
# connect: no container needed
# --------------------------------------------------------------------------------------------
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/start_singularity"
SESSION_DIR="${STATE_DIR}/sessions"

explain_job_without_session() {   # connect was called before the job wrote its session file
    local jid="$1" st log
    command -v squeue >/dev/null 2>&1 || fatal "no session file for job ${jid} and no squeue here to ask SLURM about it"
    st="$(squeue -j "${jid}" -h -o '%T %R %M' 2>/dev/null || true)"
    log="$(scontrol show job "${jid}" 2>/dev/null | awk -F= '/StdOut=/{print $2; exit}' || true)"
    case "${st}" in
        PENDING*)  info "job ${jid} is PENDING (${st#PENDING }): no node yet. Retry 'connect' once squeue shows it RUNNING." ;;
        RUNNING*)  info "job ${jid} is RUNNING for ${st##* } but has not written its session file yet: the start-up checks take 1-2 min on a cold node."
                   info "Retry in a minute. Progress: tail -f ${log:-<see the job log>}"
                   [[ -n "${log}" && -f "${log}" ]] && { echo "----- last lines of the log -----"; tail -n 8 "${log}" | cut -c1-160; } ;;
        "")        info "job ${jid} is no longer in the queue and left no session file: it ended before JupyterLab started."
                   info "sacct: $(sacct -j "${jid}" -X --noheader --format=State,Elapsed,MaxRSS 2>/dev/null | head -1 | tr -s ' ' || true)"
                   [[ -n "${log}" && -f "${log}" ]] && { echo "----- last lines of ${log} -----"; tail -n 15 "${log}" | cut -c1-160; }
                   [[ -n "${log}" && -f "${log%.out}.err" ]] && { echo "----- last lines of ${log%.out}.err -----"; tail -n 8 "${log%.out}.err" | cut -c1-160; } ;;
        *)         info "job ${jid}: ${st}; no session file yet (log: ${log:-?})" ;;
    esac
    exit 1
}
if [[ "${MODE}" == connect ]]; then
    if [[ -n "${CONNECT_JOB}" ]]; then
        f="${SESSION_DIR}/${CONNECT_JOB}.env"
        [[ -f "${f}" ]] || explain_job_without_session "${CONNECT_JOB}"
    else
        f="$(ls -t "${SESSION_DIR}"/*.env 2>/dev/null | head -1 || true)"
        if [[ -z "${f}" ]]; then
            if command -v squeue >/dev/null 2>&1; then
                jid="$(squeue --me -h -o '%i %j' 2>/dev/null | awk '$2 ~ /jupyter/ {print $1; exit}' || true)"
                [[ -n "${jid}" ]] && explain_job_without_session "${jid}"
            fi
            fatal "no jupyter sessions recorded under ${SESSION_DIR}; start one with 'sbatch jupyter' or 'jupyter'"
        fi
    fi
    # shellcheck disable=SC1090
    source "${f}"
    state="<not a SLURM job>"
    if [[ "${JOB_ID}" =~ ^[0-9]+$ ]] && command -v squeue >/dev/null 2>&1; then
        state="$(squeue -j "${JOB_ID}" -h -o '%T' 2>/dev/null || true)"
        [[ -n "${state}" ]] || state="<not in the queue any more (session ended?)>"
    fi
    case "${STATUS:-running}" in
        starting) state+=" — JupyterLab is STARTING (start-up checks running); the URL below will work in a minute" ;;
        failed)   state+=" — the start-up checks FAILED; see the job log: ${LOG_OUT:-?}" ;;
        ended)    state+=" — session ENDED at ${ENDED_AT:-?}" ;;
    esac
    cat <<INFO
============================================================
${PROJECT_NAME} JupyterLab session ${JOB_ID}
============================================================
  state         : ${state}
  compute node  : ${COMPUTE_NODE}
  port          : ${PORT}
  started       : ${STARTED_AT}
  log           : ${LOG_OUT:-<terminal>}

1. On your laptop:
       ${SSH_TUNNEL}
2. In your browser:
       ${JUPYTER_URL}
3. To stop:
       $([[ "${JOB_ID}" =~ ^[0-9]+$ ]] && printf 'scancel %s' "${JOB_ID}" || printf 'press Ctrl-C in the terminal running it')
============================================================
INFO
    exit 0
fi

# --------------------------------------------------------------------------------------------
# Resolve paths (needed by every other mode, including sbatch/srun before submission)
# --------------------------------------------------------------------------------------------
[[ -n "${SCRATCH_DIR}" ]] || fatal "--scratch DIR is required (or export SCRATCH_DIR)"
[[ -d "${SCRATCH_DIR}" ]] || fatal "scratch directory not found: ${SCRATCH_DIR}"
[[ -w "${SCRATCH_DIR}" ]] || fatal "scratch directory is not writable: ${SCRATCH_DIR}"
SCRATCH_DIR="$(abspath "${SCRATCH_DIR}")"

[[ -n "${WORKDIR}" ]] || WORKDIR="${PWD}"
[[ -d "${WORKDIR}" ]] || fatal "working directory not found: ${WORKDIR}"
WORKDIR="$(abspath "${WORKDIR}")"

[[ -n "${IMAGE}" ]] || IMAGE="${SELF_DIR}/${PROJECT_NAME}.sif"
[[ -s "${IMAGE}" ]] || fatal "image not found or empty: ${IMAGE} (use --image)"
IMAGE="$(abspath "${IMAGE}")"

if [[ -z "${CONTAINER_ENGINE}" ]]; then
    for e in apptainer singularity; do command -v "${e}" >/dev/null 2>&1 && { CONTAINER_ENGINE="${e}"; break; }; done
    [[ -n "${CONTAINER_ENGINE}" ]] || fatal "neither apptainer nor singularity is on PATH (module load apptainer?)"
fi
CONTAINER_ENGINE="$(command -v "${CONTAINER_ENGINE}" 2>/dev/null || true)"
[[ -x "${CONTAINER_ENGINE}" ]] || fatal "container engine not found: ${CONTAINER_ENGINE}"

# host path -> container path for the two mounted trees
to_container_path() {
    local p="$1"
    case "${p}" in
        "${WORKDIR}")       printf '/workspace' ;;
        "${WORKDIR}"/*)     printf '/workspace/%s' "${p#"${WORKDIR}"/}" ;;
        "${SCRATCH_DIR}")   printf '/scratch' ;;
        "${SCRATCH_DIR}"/*) printf '/scratch/%s' "${p#"${SCRATCH_DIR}"/}" ;;
        *)                  printf '%s' "${p}" ;;
    esac
}
if [[ "${NOTEBOOK_DIR}" != /workspace* && "${NOTEBOOK_DIR}" != /scratch* && -d "${NOTEBOOK_DIR}" ]]; then
    NOTEBOOK_DIR="$(to_container_path "$(abspath "${NOTEBOOK_DIR}")")"
fi
case "${NOTEBOOK_DIR}" in /workspace*|/scratch*) ;; *) fatal "--notebook-dir must be inside --workdir or --scratch: ${NOTEBOOK_DIR}" ;; esac

HOST_USER="$(id -un)"; HOST_UID="$(id -u)"; HOST_GID="$(id -g)"; HOST_HOME="${HOME:?HOME is not set}"

# --------------------------------------------------------------------------------------------
# sbatch / srun: validate resources, serialise the options, submit, exit
# --------------------------------------------------------------------------------------------
inner_options() {   # the resolved options, as flags for the job-side invocation
    local o=( --image "${IMAGE}" --workdir "${WORKDIR}" --scratch "${SCRATCH_DIR}" --notebook-dir "${NOTEBOOK_DIR}" )
    [[ -n "${CONTAINER_ENGINE}" ]] && o+=( --engine "$(basename "${CONTAINER_ENGINE}")" )
    case "${USE_GPU}" in 1) o+=( --gpu ) ;; 0) o+=( --no-gpu ) ;; esac
    [[ -n "${CUDA_DEVICES}" ]]  && o+=( --cuda-devices "${CUDA_DEVICES}" )
    [[ "${RUN_SMOKE}" == 0 ]]   && o+=( --no-smoke )
    [[ "${VERBOSE}" == 1 ]]     && o+=( --verbose )
    [[ "${BIND_SLURM}" == 0 ]]  && o+=( --no-slurm )
    [[ "${BIND_SSH}" == 0 ]]    && o+=( --no-ssh )
    [[ "${BIND_CLAUDE}" == 0 ]] && o+=( --no-claude )
    [[ "${BIND_CODEX}" == 0 ]]  && o+=( --no-codex )
    for x in ${HOST_TOOLS[@]+"${HOST_TOOLS[@]}"};     do o+=( --host-tool "${x}" ); done
    [[ -n "${JUPYTER_PORT}" ]]  && o+=( --port "${JUPYTER_PORT}" )
    [[ -n "${LOGIN_HOST}" ]]    && o+=( --login-host "${LOGIN_HOST}" )
    local x
    for x in ${EXTRA_BINDS[@]+"${EXTRA_BINDS[@]}"};   do o+=( --bind "${x}" ); done
    for x in ${EXTRA_ENVS[@]+"${EXTRA_ENVS[@]}"};     do o+=( --env "${x}" ); done
    for x in ${JUPYTER_ARGS[@]+"${JUPYTER_ARGS[@]}"}; do o+=( --jupyter-arg "${x}" ); done
    [[ ${#CMD[@]} -gt 0 ]] && o+=( -- "${CMD[@]}" )
    printf '%s\0' "${o[@]}"
}

if [[ "${MODE}" == sbatch || "${MODE}" == srun ]]; then
    command -v "${MODE}" >/dev/null 2>&1 || fatal "${MODE} not found on this host (run this from a SLURM login node)"
    missing=()
    [[ -n "${SLURM_PARTITION}" ]] || missing+=( "--partition" )
    [[ -n "${SLURM_TIME}" ]]      || missing+=( "--time" )
    [[ -n "${SLURM_CPUS}" ]]      || missing+=( "--cpus" )
    [[ -n "${SLURM_MEM}" ]]       || missing+=( "--mem" )
    [[ ${#missing[@]} -eq 0 ]] || fatal "no built-in SLURM defaults: give ${missing[*]} (or export SLURM_PARTITION/SLURM_TIME/SLURM_CPUS/SLURM_MEM)"
    case "${SLURM_MEM}" in
        *[KkMmGgTt]|*[KkMmGgTt][Bb]) ;;
        *[0-9]) fatal "--mem ${SLURM_MEM} has no unit: SLURM would read it as ${SLURM_MEM} megabytes. Write e.g. --mem ${SLURM_MEM}G" ;;
        *) fatal "--mem must be a size such as 64G or 128000M, got '${SLURM_MEM}'" ;;
    esac
    mem_num="$(printf '%s' "${SLURM_MEM}" | tr -dc 0-9)"
    case "${SLURM_MEM}" in *[Kk]*) mem_mb=$(( mem_num / 1024 )) ;; *[Mm]*) mem_mb=${mem_num} ;; *[Gg]*) mem_mb=$(( mem_num * 1024 )) ;; *) mem_mb=$(( mem_num * 1048576 )) ;; esac
    [[ "${mem_mb}" -ge 8192 ]] || warn "--mem ${SLURM_MEM}: the image needs about 8 GiB just to import torch and RAPIDS; the start-up checks will be killed below that"
    [[ "${SUBMODE}" != jupyter || -n "${SLURM_GPUS}" ]] || warn "no --gpus given: the Jupyter job will run without a GPU"
    if [[ "${SUBMODE}" == jupyter && -z "${LOGIN_HOST}" ]]; then
        LOGIN_HOST="$(hostname -f 2>/dev/null || hostname)"
        warn "--login-host not given; the tunnel command will use this host: ${LOGIN_HOST}"
    fi
    JOB_NAME="${SLURM_JOB_NAME_OPT:-${PROJECT_NAME}-${SUBMODE}}"
    LOG_DIR="${SLURM_LOG_DIR:-${SCRATCH_DIR}/.start_singularity/slurm_logs}"
    ( umask "${ORIG_UMASK}"; mkdir -p "${LOG_DIR}" ) || fatal "cannot create log directory ${LOG_DIR}"
    SELF_ABS="$(abspath "${SELF}")"
    res=( "--job-name=${JOB_NAME}" "--partition=${SLURM_PARTITION}" "--time=${SLURM_TIME}" "--cpus-per-task=${SLURM_CPUS}"
          "--mem=${SLURM_MEM}" --nodes=1 --ntasks=1 "--chdir=${WORKDIR}" )
    [[ -n "${SLURM_GPUS}" ]]    && res+=( "--gpus=${SLURM_GPUS}" )
    [[ -n "${SLURM_ACCOUNT}" ]] && res+=( "--account=${SLURM_ACCOUNT}" )
    res+=( ${SBATCH_ARGS[@]+"${SBATCH_ARGS[@]}"} )
    mapfile -d '' inner < <(inner_options)
    if [[ "${MODE}" == sbatch ]]; then
        res+=( "--output=${LOG_DIR}/${JOB_NAME}.%j.out" "--error=${LOG_DIR}/${JOB_NAME}.%j.err" )
        if [[ "${DRY_RUN}" == 1 ]]; then
            printf 'sbatch'; printf ' %q' "${res[@]}" "${SELF_ABS}" "${SUBMODE}" "${inner[@]}"; printf '\n'; exit 0
        fi
        out="$(sbatch "${res[@]}" "${SELF_ABS}" "${SUBMODE}" "${inner[@]}")" || fatal "sbatch failed"
        info "${out}"
        jid="$(printf '%s' "${out}" | grep -oE '[0-9]+$' || true)"
        info "log: ${LOG_DIR}/${JOB_NAME}.${jid:-<jobid>}.out"
        case "${SUBMODE}" in
            jupyter) info "when the job is running:  bash ${SELF_ABS} connect ${jid}" ;;
            claude)  info "attach from your laptop with the pairing shown in the log, or: scancel ${jid:-<jobid>} to stop" ;;
        esac
        exit 0
    else
        res+=( --pty )
        if [[ "${DRY_RUN}" == 1 ]]; then
            printf 'srun'; printf ' %q' "${res[@]}" "${SELF_ABS}" "${SUBMODE}" "${inner[@]}"; printf '\n'; exit 0
        fi
        exec srun "${res[@]}" "${SELF_ABS}" "${SUBMODE}" "${inner[@]}"
    fi
fi

# --------------------------------------------------------------------------------------------
# From here on we are on the machine that runs the container (login node, compute node, laptop VM)
# --------------------------------------------------------------------------------------------
"${CONTAINER_ENGINE}" inspect "${IMAGE}" >/dev/null 2>&1 || fatal "the engine cannot inspect ${IMAGE}"

GPU_FLAGS=()
if [[ "${USE_GPU}" == auto ]]; then
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then USE_GPU=1; else USE_GPU=0; fi
fi
if [[ "${USE_GPU}" == 1 ]]; then
    command -v nvidia-smi >/dev/null 2>&1 || fatal "--gpu requested but nvidia-smi is not available (use --no-gpu)"
    nvidia-smi -L >/dev/null 2>&1 || fatal "--gpu requested but no NVIDIA GPU is visible (use --no-gpu)"
    GPU_FLAGS=( --nv )
fi

# Never inherit Python or bind settings from the calling shell (cf. runtime_isolation.sh).
unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONUSERBASE
unset APPTAINER_BIND APPTAINER_BINDPATH SINGULARITY_BIND SINGULARITY_BINDPATH
unset APPTAINERENV_PYTHONPATH SINGULARITYENV_PYTHONPATH APPTAINERENV_PYTHONHOME SINGULARITYENV_PYTHONHOME

# Private temporary root: HOME, staged host tools/libraries, passwd/group, jupyter runtime files.
TEMP_BASE="${TMPDIR:-/tmp}"; [[ -d "${TEMP_BASE}" && -w "${TEMP_BASE}" ]] || TEMP_BASE=/tmp
TEMP_ROOT="$(mktemp -d "${TEMP_BASE%/}/start_singularity.${HOST_USER}.XXXXXX")" || fatal "cannot create a temporary directory under ${TEMP_BASE}"
TEMP_HOME="${TEMP_ROOT}/home"
STAGE_BIN="${TEMP_ROOT}/host/bin"
STAGE_LIB="${TEMP_ROOT}/host/lib"
STAGE_ETC="${TEMP_ROOT}/etc"
mkdir -p "${TEMP_HOME}/.local/bin" "${TEMP_HOME}/.cache" "${TEMP_HOME}/.config" "${STAGE_BIN}" "${STAGE_LIB}" "${STAGE_ETC}"
chmod 700 "${TEMP_ROOT}" "${TEMP_HOME}"

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "${SESSION_FILE:-}" && -f "${SESSION_FILE}" ]]; then
        grep -q '^STATUS="running"' "${SESSION_FILE}" 2>/dev/null && sed -i 's/^STATUS=.*/STATUS="ended"/' "${SESSION_FILE}" 2>/dev/null || sed -i 's/^STATUS="starting"/STATUS="failed"/' "${SESSION_FILE}" 2>/dev/null || true
        printf 'ENDED_AT="%s"\n' "$(date -Iseconds)" >> "${SESSION_FILE}"
    fi
    if [[ -n "${TEMP_ROOT:-}" && -d "${TEMP_ROOT}" ]]; then
        case "${TEMP_ROOT}" in "${TEMP_BASE%/}"/start_singularity.*) rm -rf -- "${TEMP_ROOT}" ;; esac
    fi
    return "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

# --------------------------------------------------------------------------------------------
# Binds and environment
# --------------------------------------------------------------------------------------------
BINDS=( --bind "${WORKDIR}:/workspace" --bind "${SCRATCH_DIR}:/scratch" --bind "${TEMP_HOME}:${HOST_HOME}" )
CONTAINER_PATH="${HOST_HOME}/.local/bin:/opt/host/bin:/scratch/.start_singularity/uv/bin:/opt/venv/bin:/opt/node/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# LD_LIBRARY_PATH is never replaced inside the container: `--nv` injects the host driver libraries through it
# (/.singularity.d/libs) and the image adds /usr/local/cuda/lib64; /opt/host/lib is prepended at run time.
NOTES=()

bind_if_exists() {   # src dst [ro]
    local src="$1" dst="$2" mode="${3:-}"
    [[ -e "${src}" ]] || return 1
    BINDS+=( --bind "${src}:${dst}${mode:+:${mode}}" )
    debug "bind ${src} -> ${dst} ${mode}"
}
for b in ${EXTRA_BINDS[@]+"${EXTRA_BINDS[@]}"}; do
    src="${b%%:*}"; [[ -e "${src}" ]] || fatal "--bind source not found: ${src}"
    BINDS+=( --bind "${b}" )
done

# Architecture of the image (host tools of another architecture cannot run inside it) and its shared
# libraries (to decide which host libraries must be staged).
CONTAINER_ARCH="$("${CONTAINER_ENGINE}" exec "${IMAGE}" uname -m 2>/dev/null || printf 'x86_64')"
elf_arch() {   # x86_64 | aarch64 | i386 | script | unknown(..)
    local magic machine
    magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
    [[ "${magic}" == 7f454c46 ]] || { printf 'script'; return; }
    machine="$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')"
    case "${machine}" in 3e00) printf 'x86_64' ;; b700) printf 'aarch64' ;; 0300) printf 'i386' ;; *) printf 'unknown(%s)' "${machine}" ;; esac
}
CONTAINER_LIBS="${TEMP_ROOT}/container-libs.txt"
"${CONTAINER_ENGINE}" exec "${IMAGE}" /usr/sbin/ldconfig -p 2>/dev/null | awk 'NR>1 && $1 ~ /\.so/ {print $1}' | sort -u > "${CONTAINER_LIBS}" || true
[[ -s "${CONTAINER_LIBS}" ]] || warn "could not list the image's libraries; host libraries will be staged only when clearly missing"

STAGED_LIBS=()
stage_libs_for() {   # file ... : copy every library a host binary/plugin needs that the image does not have
    local f line lib so
    for f in "$@"; do
        [[ -e "${f}" ]] || continue
        while read -r line; do   # default IFS trims the leading tab of ldd output
            if [[ "${line}" == *"=> not found"* ]]; then warn "$(basename "${f}") needs ${line%% *}, which the host cannot find either"; continue; fi
            [[ "${line}" == *"=>"* ]] || continue
            lib="${line#*=> }"; lib="${lib%% (*}"
            [[ -n "${lib}" && -e "${lib}" ]] || continue
            so="$(basename "${lib}")"
            case "${so}" in   # the image's own C runtime must never be shadowed
                libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|ld-linux*|libnss_*|libgcc_s.so.*|libstdc++.so.*|libanl.so.*) continue ;;
            esac
            grep -qxF "${so}" "${CONTAINER_LIBS}" 2>/dev/null && continue
            [[ -e "${STAGE_LIB}/${so}" ]] && continue
            cp -L "${lib}" "${STAGE_LIB}/${so}" 2>/dev/null && { STAGED_LIBS+=( "${so}" ); debug "staged ${lib}"; }
        done < <(ldd "${f}" 2>/dev/null || true)
    done
}
stage_tool() {   # name [src]: put a host executable on the container PATH (/opt/host/bin), with its libraries
    local name="$1" src="${2:-}" real
    [[ -n "${src}" ]] || src="$(command -v "${name}" 2>/dev/null || true)"
    [[ -n "${src}" && -x "${src}" ]] || return 1
    real="$(readlink -f "${src}")"
    local arch; arch="$(elf_arch "${real}")"
    if [[ "${arch}" != script && "${arch}" != "${CONTAINER_ARCH}" ]]; then
        warn "${name} is a ${arch} binary but the image is ${CONTAINER_ARCH}; not bound"
        return 1
    fi
    if [[ $(stat -c %s "${real}") -lt $((20 * 1024 * 1024)) ]]; then
        cp -L "${real}" "${STAGE_BIN}/${name}" && chmod u+x "${STAGE_BIN}/${name}"
    else   # big binaries (claude) are bound, not copied
        BINDS+=( --bind "${real}:/opt/host/bin/${name}:ro" )
    fi
    stage_libs_for "${real}"
    debug "tool ${name} <- ${real}"
    return 0
}

# ---- SLURM clients + munge (so sbatch/squeue/... work inside the container) ----
SLURM_STATE="not bound"; SLURM_BOUND=0
if [[ "${BIND_SLURM}" == 1 ]]; then
    if command -v sbatch >/dev/null 2>&1; then
        SLURM_BOUND=1
        slurm_tools=(); missing_tools=()
        for t in sbatch squeue scancel sinfo srun scontrol sacct sacctmgr; do
            if stage_tool "${t}"; then slurm_tools+=( "${t}" ); else missing_tools+=( "${t}" ); fi
        done
        slurm_conf="${SLURM_CONF:-}"; plugin_dir=""; auth_info=""
        if cfg="$(scontrol show config 2>/dev/null)"; then
            [[ -n "${slurm_conf}" ]] || slurm_conf="$(awk -F'= ' '/^SLURM_CONF[[:space:]]*=/{print $2; exit}' <<<"${cfg}")"
            plugin_dir="$(awk -F'= ' '/^PluginDir[[:space:]]*=/{print $2; exit}' <<<"${cfg}")"
            auth_info="$(awk -F'= ' '/^AuthInfo[[:space:]]*=/{print $2; exit}' <<<"${cfg}")"
        fi
        [[ -n "${slurm_conf}" ]] || for c in /etc/slurm/slurm.conf /etc/slurm-llnl/slurm.conf /usr/local/etc/slurm.conf; do [[ -f "${c}" ]] && { slurm_conf="${c}"; break; }; done
        [[ -n "${slurm_conf}" && -f "${slurm_conf}" ]] || warn "slurm.conf not found (scontrol show config failed); SLURM commands may not work inside"
        if [[ -f "${slurm_conf}" ]]; then
            conf_dir="$(dirname "${slurm_conf}")"
            bind_if_exists "${conf_dir}" "${conf_dir}" ro
            [[ -n "${plugin_dir}" ]] || plugin_dir="$(awk -F= '/^PluginDir[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${slurm_conf}")"
        fi
        [[ -n "${plugin_dir}" ]] || for d in /usr/lib64/slurm /usr/lib/x86_64-linux-gnu/slurm-wlm /usr/lib/slurm; do [[ -d "${d}" ]] && { plugin_dir="${d}"; break; }; done
        for d in ${plugin_dir//:/ }; do
            if [[ -d "${d}" ]]; then bind_if_exists "${d}" "${d}" ro; stage_libs_for "${d}"/*.so; else warn "SLURM plugin dir not found: ${d}"; fi
        done
        munge_sock=""
        [[ "${auth_info}" == *socket=* ]] && { munge_sock="${auth_info#*socket=}"; munge_sock="${munge_sock%%,*}"; }
        [[ -n "${munge_sock}" ]] || for s in /run/munge/munge.socket.2 /var/run/munge/munge.socket.2; do [[ -S "${s}" ]] && { munge_sock="${s}"; break; }; done
        if [[ -S "${munge_sock}" ]]; then bind_if_exists "$(dirname "${munge_sock}")" "$(dirname "${munge_sock}")"
        else warn "munge socket not found; sbatch inside the container will fail to authenticate"; fi
        SLURM_STATE="${slurm_tools[*]:-none}"
        [[ ${#missing_tools[@]} -gt 0 ]] && SLURM_STATE+=" (missing: ${missing_tools[*]})"
        [[ -n "${slurm_conf}" ]] && SLURM_STATE+="; conf $(dirname "${slurm_conf}")"
        [[ -n "${plugin_dir}" ]] && SLURM_STATE+="; plugins ${plugin_dir}"
        # minimal passwd/group so sbatch/ssh can resolve the uid, root and SlurmUser inside
        slurm_user="$(awk -F= '/^SlurmUser[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${slurm_conf}" 2>/dev/null || true)"
    else
        SLURM_STATE="sbatch not on this host"
    fi
fi
{
    grep '^root:' /etc/passwd 2>/dev/null || echo 'root:x:0:0:root:/root:/bin/bash'
    getent passwd "${HOST_UID}" 2>/dev/null || echo "${HOST_USER}:x:${HOST_UID}:${HOST_GID}:${HOST_USER}:${HOST_HOME}:/bin/bash"
    if [[ -n "${slurm_user:-}" ]]; then getent passwd "${slurm_user}" 2>/dev/null || true; fi
    echo 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin'
} | awk -F: '!seen[$1]++' > "${STAGE_ETC}/passwd"
{
    grep '^root:' /etc/group 2>/dev/null || echo 'root:x:0:'
    getent group "${HOST_GID}" 2>/dev/null || echo "${HOST_USER}:x:${HOST_GID}:${HOST_USER}"
    if [[ -n "${slurm_user:-}" ]]; then getent group "${slurm_user}" 2>/dev/null || true; fi
    echo 'nogroup:x:65534:'
} | awk -F: '!seen[$1]++' > "${STAGE_ETC}/group"
BINDS+=( --bind "${STAGE_ETC}/passwd:/etc/passwd:ro" --bind "${STAGE_ETC}/group:/etc/group:ro" )

# ---- ssh + git ----
SSH_STATE="not bound"; SSH_BOUND=0; GH_BOUND=0; SSH_NOTE="ssh not on this host"; GH_NOTE="gh not on this host"
if [[ "${BIND_SSH}" == 1 ]]; then
    parts=()
    if stage_tool ssh; then
        SSH_BOUND=1; SSH_NOTE="ssh from $(dirname "$(readlink -f "$(command -v ssh)")")"
        bind_if_exists /etc/ssh /etc/ssh ro || true
        if bind_if_exists "${HOST_HOME}/.ssh" "${HOST_HOME}/.ssh" ro; then SSH_NOTE+=", ~/.ssh ro"; else SSH_NOTE+=", no ~/.ssh"; fi
        if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then BINDS+=( --bind "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}" ); SSH_NOTE+=", agent socket"; fi
        parts+=( "ssh" )
    else
        [[ -n "$(command -v ssh 2>/dev/null)" ]] && SSH_NOTE="ssh not usable inside (see warning above)"
        parts+=( "no ssh" )
    fi
    stage_tool ssh-keygen >/dev/null 2>&1 || true
    bind_if_exists "${HOST_HOME}/.gitconfig" "${HOST_HOME}/.gitconfig" ro && parts+=( "~/.gitconfig" )
    bind_if_exists "${HOST_HOME}/.config/git" "${HOST_HOME}/.config/git" ro && parts+=( "~/.config/git" )
    if stage_tool gh; then
        GH_BOUND=1; GH_NOTE="gh from $(dirname "$(readlink -f "$(command -v gh)")")"; parts+=( gh )
        if bind_if_exists "${HOST_HOME}/.config/gh" "${HOST_HOME}/.config/gh" ro; then GH_NOTE+=", ~/.config/gh ro"; parts+=( "~/.config/gh" ); fi
    fi
    SSH_STATE="${parts[*]}"
fi

# ---- Claude Code ----
CLAUDE_STATE="not bound"; CLAUDE_BOUND=0
if [[ "${BIND_CLAUDE}" == 1 ]]; then
    claude_src="$(command -v claude 2>/dev/null || true)"
    [[ -n "${claude_src}" ]] || { [[ -x "${HOST_HOME}/.local/bin/claude" ]] && claude_src="${HOST_HOME}/.local/bin/claude"; }
    if [[ -n "${claude_src}" ]]; then
        claude_real="$(readlink -f "${claude_src}")"
        # state (history, settings, plugins, credentials) is bound read-write, so it persists and refreshes in place
        bind_if_exists "${HOST_HOME}/.claude" "${HOST_HOME}/.claude" || { mkdir -p "${HOST_HOME}/.claude" && BINDS+=( --bind "${HOST_HOME}/.claude:${HOST_HOME}/.claude" ); }
        if [[ -f "${HOST_HOME}/.claude.json" ]]; then BINDS+=( --bind "${HOST_HOME}/.claude.json:${HOST_HOME}/.claude.json" )
        else NOTES+=( "~/.claude.json does not exist on the host: log in to Claude once outside the container so the login persists" ); fi
        case "${claude_real}" in
            "${HOST_HOME}/.claude/"*)  ln -s "${claude_real}" "${TEMP_HOME}/.local/bin/claude" ;;   # already visible through ~/.claude
            *) stage_tool claude "${claude_real}" ;;
        esac
        stage_libs_for "${claude_real}"
        CLAUDE_STATE="$(basename "${claude_real}") from ${claude_real%/*}; ~/.claude rw"; CLAUDE_BOUND=1
    else
        CLAUDE_STATE="claude not on this host"
    fi
fi

# ---- Codex / Antigravity ----
CODEX_STATE="not bound"; CODEX_BOUND=0; AGY_BOUND=0; CODEX_NOTE="codex not on this host"; AGY_NOTE="agy/antigravity not on this host"
if [[ "${BIND_CODEX}" == 1 ]]; then
    parts=()
    codex_src="$(command -v codex 2>/dev/null || true)"
    [[ -n "${codex_src}" ]] || { [[ -x "${HOST_HOME}/.codex/packages/standalone/current/bin/codex" ]] && codex_src="${HOST_HOME}/.codex/packages/standalone/current/bin/codex"; }
    if [[ -n "${codex_src}" ]]; then
        codex_real="$(readlink -f "${codex_src}")"; CODEX_NOTE="codex from ${codex_real%/*}; ~/.codex rw"
        bind_if_exists "${HOST_HOME}/.codex" "${HOST_HOME}/.codex" || true
        case "${codex_real}" in
            "${HOST_HOME}/.codex/"*) ln -s "${codex_real}" "${TEMP_HOME}/.local/bin/codex"; stage_libs_for "${codex_real}" ;;
            *) stage_tool codex "${codex_real}" ;;
        esac
        parts+=( "codex" ); CODEX_BOUND=1
    fi
    for t in agy antigravity; do
        t_src="$(command -v "${t}" 2>/dev/null || true)"
        [[ -n "${t_src}" ]] || for c in "${HOST_HOME}/.gemini/antigravity-cli/bin/${t}" "${HOST_HOME}/.gemini/antigravity-cli/${t}"; do [[ -x "${c}" ]] && { t_src="${c}"; break; }; done
        [[ -n "${t_src}" ]] || continue
        t_real="$(readlink -f "${t_src}")"; AGY_NOTE="${t} from ${t_real%/*}; ~/.gemini rw"
        case "${t_real}" in
            "${HOST_HOME}/.gemini/"*) ln -s "${t_real}" "${TEMP_HOME}/.local/bin/${t}"; stage_libs_for "${t_real}" ;;
            *) stage_tool "${t}" "${t_real}" ;;
        esac
        parts+=( "${t}" ); AGY_BOUND=1
    done
    [[ ${#parts[@]} -gt 0 ]] && bind_if_exists "${HOST_HOME}/.gemini" "${HOST_HOME}/.gemini" || true
    CODEX_STATE="${parts[*]:-codex/agy not on this host}"
fi

BINDS+=( --bind "${STAGE_BIN}:/opt/host/bin:ro" --bind "${STAGE_LIB}:/opt/host/lib:ro" )

# ---- extra --host-tool programs (native binaries, or Node.js scripts run with the image's node) ----
bound_dirs=()
bind_dir_once() {   # bind a host directory read-only at the same path, once
    local d="$1" x
    for x in ${bound_dirs[@]+"${bound_dirs[@]}"}; do [[ "${d}" == "${x}" || "${d}" == "${x}"/* ]] && return 0; done
    bind_if_exists "${d}" "${d}" ro && bound_dirs+=( "${d}" )
}
bind_host_cli() {   # NAME: a native executable (staged like ssh) or a Node.js script (node + its node_modules tree bound; wrapper on PATH)
    local name="$1" src real root first
    src="$(command -v "${name}" 2>/dev/null || true)"; [[ -n "${src}" ]] || { HOST_CLI_NOTE="${name} not on this host"; return 1; }
    real="$(readlink -f "${src}")"
    if [[ "$(elf_arch "${real}")" != script ]]; then
        stage_tool "${name}" "${real}" || { HOST_CLI_NOTE="${name} is of another architecture than the image"; return 1; }
        HOST_CLI_NOTE="${name} from ${real%/*}"; return 0
    fi
    first="$(head -c 200 "${real}" | head -1 || true)"
    if [[ "${first}" == *node* ]]; then
        root="${real}"; while [[ "${root}" != / && "$(basename "${root}")" != node_modules ]]; do root="$(dirname "${root}")"; done
        [[ "${root}" != / ]] || { HOST_CLI_NOTE="${name}: no node_modules directory above ${real}"; return 1; }
        bind_dir_once "${root}"
        printf '#!/bin/bash\nexec node %q "$@"\n' "${real}" > "${TEMP_HOME}/.local/bin/${name}"; chmod u+x "${TEMP_HOME}/.local/bin/${name}"
        HOST_CLI_NOTE="${name} from ${root} (Node.js script, run with the image's node)"; return 0
    fi
    # any other interpreter script (bash, python): copy it; its interpreter must exist in the image
    cp -L "${real}" "${STAGE_BIN}/${name}" && chmod u+x "${STAGE_BIN}/${name}"
    HOST_CLI_NOTE="${name} from ${real%/*} (script: ${first#\#!})"; return 0
}
EXTRA_TOOLS_STATE=""   # newline-separated "name|bound/absent|note" for the report
for t in ${HOST_TOOLS[@]+"${HOST_TOOLS[@]}"}; do
    if bind_host_cli "${t}"; then EXTRA_TOOLS_STATE+="${t}|bound|${HOST_CLI_NOTE}"$'\n'
    else warn "--host-tool ${t}: ${HOST_CLI_NOTE}"; EXTRA_TOOLS_STATE+="${t}|absent|${HOST_CLI_NOTE}"$'\n'; fi
done
# ---- uv (in the image): caches, managed Pythons and `uv tool` installs persist under scratch ----
( umask "${ORIG_UMASK}"; mkdir -p "${SCRATCH_DIR}/.start_singularity/uv/bin" "${SCRATCH_DIR}/.start_singularity/uv/cache" "${SCRATCH_DIR}/.start_singularity/uv/python" "${SCRATCH_DIR}/.start_singularity/uv/tools" ) 2>/dev/null || true

tool_status() {   # bound(0/1) enabled(0/1) disable-flag note  ->  "bound|note" / "off|note" / "absent|note"
    if [[ "$2" == 0 ]]; then printf 'off|disabled with %s' "$3"
    elif [[ "$1" == 1 ]]; then printf 'bound|%s' "$4"
    else printf 'absent|%s' "$4"; fi
}
SMOKE_SLURM="$(tool_status "${SLURM_BOUND:-0}" "${BIND_SLURM}" --no-slurm "${SLURM_STATE}")"
SMOKE_SSH="$(tool_status "${SSH_BOUND:-0}" "${BIND_SSH}" --no-ssh "${SSH_NOTE}")"
SMOKE_GH="$(tool_status "${GH_BOUND:-0}" "${BIND_SSH}" --no-ssh "${GH_NOTE}")"
SMOKE_CLAUDE="$(tool_status "${CLAUDE_BOUND:-0}" "${BIND_CLAUDE}" --no-claude "${CLAUDE_STATE}")"
SMOKE_CODEX="$(tool_status "${CODEX_BOUND:-0}" "${BIND_CODEX}" --no-codex "${CODEX_NOTE}")"
SMOKE_AGY="$(tool_status "${AGY_BOUND:-0}" "${BIND_CODEX}" --no-codex "${AGY_NOTE}")"

# ---- shell start-up files for the private HOME ----
cat > "${TEMP_HOME}/.bash_profile" <<'EOF'
[[ -f "${HOME}/.bashrc" ]] && source "${HOME}/.bashrc"
EOF
cat > "${TEMP_HOME}/.bashrc" <<EOF
export PATH="${CONTAINER_PATH}"
case ":\${LD_LIBRARY_PATH:-}:" in *:/opt/host/lib:*) ;; *) export LD_LIBRARY_PATH="/opt/host/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}" ;; esac
export PYTHONNOUSERSITE=1
export PS1='[${PROJECT_NAME}] \u@\h:\w\$ '
alias ll='ls -lh'
cd /workspace 2>/dev/null || true
EOF

# ---- environment inside the container (explicit; the image's %environment values are overridden) ----
CONTAINER_ENV=(
    "HOME=${HOST_HOME}" "USER=${HOST_USER}" "LOGNAME=${HOST_USER}" "SHELL=/bin/bash" "TERM=${TERM:-xterm-256color}"
    "LANG=C.UTF-8" "LC_ALL=C.UTF-8"
    "PATH=${CONTAINER_PATH}" "CUDA_HOME=/usr/local/cuda"
    "PYTHONNOUSERSITE=1" "PYTHONDONTWRITEBYTECODE=1" "MPLBACKEND=Agg"
    "XLA_PYTHON_CLIENT_PREALLOCATE=false" "XLA_PYTHON_CLIENT_ALLOCATOR=platform" "TOKENIZERS_PARALLELISM=false"
    "XDG_CACHE_HOME=${HOST_HOME}/.cache" "XDG_CONFIG_HOME=${HOST_HOME}/.config"
    "MPLCONFIGDIR=${HOST_HOME}/.cache/matplotlib" "NUMBA_CACHE_DIR=${HOST_HOME}/.cache/numba"
    "CUPY_CACHE_DIR=${HOST_HOME}/.cache/cupy" "TRITON_CACHE_DIR=${HOST_HOME}/.cache/triton"
    "TORCH_EXTENSIONS_DIR=${HOST_HOME}/.cache/torch_extensions"
    "PROJECT_ROOT=/workspace" "PROJECT_SCRATCH=/scratch" "START_SINGULARITY_GPU=${USE_GPU}"
    "SMOKE_SLURM=${SMOKE_SLURM}" "SMOKE_SSH=${SMOKE_SSH}" "SMOKE_GH=${SMOKE_GH}" "SMOKE_CLAUDE=${SMOKE_CLAUDE}"
    "SMOKE_CODEX=${SMOKE_CODEX}" "SMOKE_AGY=${SMOKE_AGY}" "SMOKE_STAGED_LIBS=${STAGED_LIBS[*]:-}"
    "SMOKE_EXTRA_TOOLS=${EXTRA_TOOLS_STATE}"
    "UV_CACHE_DIR=/scratch/.start_singularity/uv/cache" "UV_PYTHON_INSTALL_DIR=/scratch/.start_singularity/uv/python"
    "UV_TOOL_DIR=/scratch/.start_singularity/uv/tools" "UV_TOOL_BIN_DIR=/scratch/.start_singularity/uv/bin" "UV_LINK_MODE=copy"
    "SMOKE_WORKDIR_HOST=${WORKDIR}" "SMOKE_SCRATCH_HOST=${SCRATCH_DIR}" "SMOKE_IMAGE=${IMAGE}" "SMOKE_MODE=${MODE}"
)
mkdir -p "${TEMP_HOME}/.cache/matplotlib" "${TEMP_HOME}/.cache/numba" "${TEMP_HOME}/.cache/cupy" "${TEMP_HOME}/.cache/triton" "${TEMP_HOME}/.cache/torch_extensions"
[[ "${USE_GPU}" == 0 ]] && CONTAINER_ENV+=( "JAX_PLATFORMS=cpu" "DS_ACCELERATOR=cpu" )
[[ -d "${WORKDIR}/capsule-3642729/cell_tools" ]]        && CONTAINER_ENV+=( "CELL_TOOLS_REPO=/workspace/capsule-3642729/cell_tools" )
[[ -f "${WORKDIR}/capsule-3642729/data/lung_atlas.h5ad" ]] && CONTAINER_ENV+=( "LUNG_ATLAS_H5AD=/workspace/capsule-3642729/data/lung_atlas.h5ad" )
[[ -n "${slurm_conf:-}" ]] && CONTAINER_ENV+=( "SLURM_CONF=${slurm_conf}" )
if [[ -n "${CUDA_DEVICES}" ]]; then CONTAINER_ENV+=( "CUDA_VISIBLE_DEVICES=${CUDA_DEVICES}" )
elif [[ ${CUDA_VISIBLE_DEVICES+x} == x ]]; then CONTAINER_ENV+=( "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}" ); fi
[[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" && "${BIND_SSH}" == 1 ]] && CONTAINER_ENV+=( "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}" )
while IFS='=' read -r k v; do [[ -n "${k}" ]] && CONTAINER_ENV+=( "${k}=${v}" ); done < <(env | grep -E '^(SLURM_|SLURMD_)' || true)
for e in ${EXTRA_ENVS[@]+"${EXTRA_ENVS[@]}"}; do [[ "${e}" == *=* ]] || fatal "--env expects KEY=VALUE: ${e}"; CONTAINER_ENV+=( "${e}" ); done

# shellcheck disable=SC2016   # the prelude is evaluated inside the container, not here
LD_PRELUDE="umask ${ORIG_UMASK}; "'case ":${LD_LIBRARY_PATH:-}:" in *:/opt/host/lib:*) ;; *) export LD_LIBRARY_PATH="/opt/host/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;; esac; exec "$@"'
container_exec() {   # run a command inside the image with the full bind/env set; keeps the container's LD_LIBRARY_PATH
    "${CONTAINER_ENGINE}" exec --cleanenv --no-home ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} "${BINDS[@]}" --pwd /workspace \
        "${IMAGE}" env "${CONTAINER_ENV[@]}" /bin/bash -c "${LD_PRELUDE}" start_singularity "$@"
}

# --------------------------------------------------------------------------------------------
# Banner (host view of the resources; the smoke test prints the view from inside the container)
# --------------------------------------------------------------------------------------------
RES_CPUS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '?')"
if [[ -n "${SLURM_MEM_PER_NODE:-}" ]]; then
    if [[ "${SLURM_MEM_PER_NODE}" -ge 1024 ]]; then RES_MEM="$(( SLURM_MEM_PER_NODE / 1024 )) GiB (SLURM allocation)"; else RES_MEM="${SLURM_MEM_PER_NODE} MB (SLURM allocation)"; fi
    [[ "${SLURM_MEM_PER_NODE}" -ge 8192 ]] || NOTES+=( "this job has only ${SLURM_MEM_PER_NODE} MB of memory (SLURM --mem without a unit means megabytes); the image needs about 8 GiB to import torch and RAPIDS, so expect the container to be killed" )
elif [[ -n "${SLURM_MEM_PER_CPU:-}" ]]; then RES_MEM="$(( SLURM_MEM_PER_CPU * ${SLURM_CPUS_PER_TASK:-1} / 1024 )) GiB (SLURM, per-cpu x cpus)"
else RES_MEM="$(awk '/MemTotal/{printf "%.0f GiB total on this host", $2/1024/1024}' /proc/meminfo 2>/dev/null || printf '?')"; fi
if [[ "${USE_GPU}" == 1 ]]; then
    RES_GPU="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', ' '{k=$1" "int($2/1024)" GiB"; n[k]++; if(!(k in o)){o[k]=++c; key[c]=k}} END{for(i=1;i<=c;i++){printf "%s%d x %s", (i>1?"; ":""), n[key[i]], key[i]}}' || true)"
    [[ -n "${CUDA_DEVICES}" ]] && RES_GPU+="; CUDA_VISIBLE_DEVICES=${CUDA_DEVICES}"
elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then RES_GPU="present but NOT used (--no-gpu)"
else RES_GPU="none visible on this host"; fi
printf '%s\n' \
    '================================================================' \
    "${PROJECT_NAME} container  (start_singularity.sh ${SCRIPT_VERSION}; mode: ${MODE})" \
    "  host        : $(hostname)${SLURM_JOB_ID:+  (SLURM job ${SLURM_JOB_ID})}" \
    "  user        : ${HOST_USER} (${HOST_UID}:${HOST_GID})" \
    "  engine      : ${CONTAINER_ENGINE}" \
    "  image       : ${IMAGE}" \
    "  workdir     : ${WORKDIR} -> /workspace" \
    "  scratch     : ${SCRATCH_DIR} -> /scratch" \
    "  HOME        : private ${TEMP_HOME} -> ${HOST_HOME}" \
    "  CPUs        : ${RES_CPUS}${SLURM_CPUS_PER_TASK:+  (SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK})}" \
    "  memory      : ${RES_MEM}" \
    "  GPU         : $([[ ${USE_GPU} == 1 ]] && printf 'used (--nv): %s' "${RES_GPU}" || printf '%s' "${RES_GPU}")" \
    "  SLURM       : ${SLURM_STATE}" \
    "  ssh/git     : ${SSH_STATE}" \
    "  Claude      : ${CLAUDE_STATE}" \
    "  Codex/agy   : ${CODEX_STATE}" \
    "  extra tools : ${EXTRA_TOOLS_STATE:+$(printf '%s' "${EXTRA_TOOLS_STATE}" | cut -d'|' -f1,3 | tr '|' ' ' | paste -sd ';' - | sed 's/;/; /g')}${EXTRA_TOOLS_STATE:-none (--host-tool NAME)}" \
    "  staged libs : ${STAGED_LIBS[*]:-none}" \
    '================================================================'
for n in ${NOTES[@]+"${NOTES[@]}"}; do warn "${n}"; done
if [[ "${VERBOSE}" == 1 ]]; then printf 'binds:\n'; printf '  %s\n' "${BINDS[@]}"; fi

if [[ "${DRY_RUN}" == 1 ]]; then
    printf '%q ' "${CONTAINER_ENGINE}" exec --cleanenv --no-home ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} "${BINDS[@]}" --pwd /workspace "${IMAGE}" env "${CONTAINER_ENV[@]}" '<command>'; printf '\n'
    exit 0
fi

jupyter_update_status() {   # starting -> running / failed, visible through `connect`
    [[ -n "${SESSION_FILE:-}" && -f "${SESSION_FILE}" ]] || return 0
    sed -i "s/^STATUS=.*/STATUS=\"$1\"/" "${SESSION_FILE}" 2>/dev/null || true
}
jupyter_prepare() {   # choose port and token, write the session file and the connection instructions (before the checks)
        pick_free_port() {
            local p
            for _ in $(seq 1 60); do
                p=$((8000 + RANDOM % 1000))
                if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && continue
                else (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && { exec 3>&-; continue; }; fi
                printf '%s' "${p}"; return 0
            done
            printf '8888'
        }
        PORT="${JUPYTER_PORT:-$(pick_free_port)}"
        TOKEN="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        COMPUTE_NODE="$(hostname)"
        JOB_ID="${SLURM_JOB_ID:-manual-${COMPUTE_NODE}-$$}"
        if [[ -z "${LOGIN_HOST}" ]]; then LOGIN_HOST="$(hostname -f 2>/dev/null || hostname)"; warn "--login-host not given; using ${LOGIN_HOST} in the tunnel command"; fi
        # runtime/data (cookie secret, server json) on node-local tmp inside the private HOME: honours mode 700;
        # user settings and workspaces (no secrets) under scratch so they persist between sessions
        JUP_SETTINGS="${SCRATCH_DIR}/.start_singularity/jupyter/${HOST_USER}/user-settings"; JUP_WORKSPACES="${SCRATCH_DIR}/.start_singularity/jupyter/${HOST_USER}/workspaces"
        ( umask "${ORIG_UMASK}"; mkdir -p "${JUP_SETTINGS}" "${JUP_WORKSPACES}" )
        mkdir -p "${TEMP_HOME}/.jupyter-session/config" "${TEMP_HOME}/.jupyter-session/data" "${TEMP_HOME}/.jupyter-session/runtime"
        chmod 700 "${TEMP_HOME}/.jupyter-session" "${TEMP_HOME}/.jupyter-session/runtime"
        CONTAINER_ENV+=(
            "JUPYTER_CONFIG_DIR=${HOST_HOME}/.jupyter-session/config" "JUPYTER_DATA_DIR=${HOST_HOME}/.jupyter-session/data"
            "JUPYTER_RUNTIME_DIR=${HOST_HOME}/.jupyter-session/runtime"
            "JUPYTERLAB_SETTINGS_DIR=/scratch/.start_singularity/jupyter/${HOST_USER}/user-settings" "JUPYTERLAB_WORKSPACES_DIR=/scratch/.start_singularity/jupyter/${HOST_USER}/workspaces"
            "JUPYTER_TOKEN=${TOKEN}"
        )
        mkdir -p "${SESSION_DIR}"; chmod 700 "${STATE_DIR}" "${SESSION_DIR}" 2>/dev/null || true
        SESSION_FILE="${SESSION_DIR}/${JOB_ID}.env"
        SSH_TUNNEL="ssh -N -L ${PORT}:${COMPUTE_NODE}:${PORT} ${HOST_USER}@${LOGIN_HOST}"
        JUPYTER_URL="http://localhost:${PORT}/lab?token=${TOKEN}"
        cat > "${SESSION_FILE}" <<EOF
STATUS="starting"
JOB_ID="${JOB_ID}"
COMPUTE_NODE="${COMPUTE_NODE}"
PORT="${PORT}"
TOKEN="${TOKEN}"
LOGIN_HOST="${LOGIN_HOST}"
SSH_TUNNEL="${SSH_TUNNEL}"
JUPYTER_URL="${JUPYTER_URL}"
NOTEBOOK_DIR="${NOTEBOOK_DIR}"
WORKDIR="${WORKDIR}"
SCRATCH_DIR="${SCRATCH_DIR}"
IMAGE="${IMAGE}"
STARTED_AT="$(date -Iseconds)"
LOG_OUT="${SLURM_JOB_ID:+$(scontrol show job "${SLURM_JOB_ID}" 2>/dev/null | awk -F= '/StdOut=/{print $2; exit}')}"
EOF
        chmod 600 "${SESSION_FILE}"
        cat <<INFO
------------------------------------------------------------
JupyterLab  (session ${JOB_ID}; root ${NOTEBOOK_DIR}; node ${COMPUTE_NODE}:${PORT})
------------------------------------------------------------
1. On your laptop, open the tunnel (leave it running):
       ${SSH_TUNNEL}
2. In your browser:
       ${JUPYTER_URL}
3. Stop: $([[ -n "${SLURM_JOB_ID:-}" ]] && printf 'scancel %s' "${SLURM_JOB_ID}" || printf 'Ctrl-C here')
   Later: bash start_singularity.sh connect ${JOB_ID}      (session file ${SESSION_FILE})
   The server starts after the checks below; until then `connect` reports the session as starting.
------------------------------------------------------------
INFO
}
if [[ "${MODE}" == jupyter ]]; then jupyter_prepare; fi

# --------------------------------------------------------------------------------------------
# Smoke test: one report of the resources, every feature group of the image, and every bound host tool
# --------------------------------------------------------------------------------------------
run_smoke_tests() {
    container_exec python - <<'PY'
import importlib, os, re, shutil, subprocess, sys, time
T0 = time.time()
GPU = os.environ.get("START_SINGULARITY_GPU") == "1"
ROWS, FATAL = [], []

def add(section, name, status, detail, t=None):
    ROWS.append((section, name, status, detail, t))

def sh(cmd, timeout=90):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"

def human(n):
    n = float(n)
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or u == "TiB":
            return f"{n:.0f} {u}" if u in ("B", "KiB", "MiB") else f"{n:.1f} {u}"
        n /= 1024

def ver(mod):
    try:
        from importlib.metadata import version
        return version(mod)
    except Exception:
        return getattr(importlib.import_module(mod), "__version__", "")

def timed(fn):
    t = time.time(); r = fn(); return r, time.time() - t

# ---------------------------------------------------------------- resources (as seen inside the container)
try:
    usable = len(os.sched_getaffinity(0))
except Exception:
    usable = os.cpu_count() or 0
node = os.cpu_count() or 0
cpu = f"{usable} usable" + (f" of {node} on the node" if node != usable else "")
for k in ("SLURM_CPUS_PER_TASK", "SLURM_CPUS_ON_NODE"):
    if os.environ.get(k): cpu += f"; {k}={os.environ[k]}"
add("resources", "CPUs", "", cpu)

meminfo = {}
try:
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1); meminfo[k] = int(v.split()[0]) * 1024
except Exception:
    pass
limit = None
try:
    cg = [l.split(":", 2)[2].strip() for l in open("/proc/self/cgroup") if l.startswith("0::")]
    cands = ([f"/sys/fs/cgroup{cg[0]}/memory.max"] if cg else []) + ["/sys/fs/cgroup/memory.max"]
    cands += ([f"/sys/fs/cgroup/memory{cg[0]}/memory.limit_in_bytes"] if cg else []) + ["/sys/fs/cgroup/memory/memory.limit_in_bytes"]
    for c in cands:
        if os.path.exists(c):
            v = open(c).read().strip()
            if v != "max" and int(v) < (1 << 60):
                limit = int(v); break
except Exception:
    pass
mem = []
if limit: mem.append(f"{human(limit)} limit for this process tree (cgroup)")
if meminfo.get("MemTotal"): mem.append(f"{human(meminfo['MemTotal'])} on the node, {human(meminfo.get('MemAvailable', 0))} available")
for k in ("SLURM_MEM_PER_NODE", "SLURM_MEM_PER_CPU"):
    if os.environ.get(k): mem.append(f"{k}={os.environ[k]} MB")
add("resources", "memory", "", "; ".join(mem) or "unknown")

gpus = []   # (index, name, total MiB, used MiB, driver, cc)
if shutil.which("nvidia-smi"):
    rc, out = sh("nvidia-smi --query-gpu=index,name,memory.total,memory.used,driver_version,compute_cap --format=csv,noheader,nounits", 30)
    if rc == 0:
        for line in out.splitlines():
            f = [x.strip() for x in line.split(",")]
            if len(f) >= 6: gpus.append((f[0], f[1], int(f[2]), int(f[3]), f[4], f[5]))
    else:
        add("resources", "nvidia-smi", "!!", f"bound but failing: {out.splitlines()[0][:120] if out else rc}")
cvd = os.environ.get("CUDA_VISIBLE_DEVICES")
if gpus:
    kinds = {(g[1], g[2] // 1024, g[4], g[5]) for g in gpus}
    if len(kinds) == 1:
        name, gib, drv, cc = next(iter(kinds))
        gtxt = f"{len(gpus)} x {name} {gib} GiB (cc {cc}, driver {drv}); memory in use per GPU [MiB]: " + ", ".join(f"{g[0]}:{g[3]}" for g in gpus)
    else:
        gtxt = f"{len(gpus)} visible: " + "; ".join(f"[{g[0]}] {g[1]} {g[2]//1024} GiB ({g[3]} MiB in use), cc {g[5]}, driver {g[4]}" for g in gpus)
    if cvd is not None: gtxt += f"; CUDA_VISIBLE_DEVICES={cvd} (only these are used)"
    if not GPU: gtxt = f"{len(gpus)} present but NOT used (--no-gpu): " + gtxt
    add("resources", "GPUs", "", gtxt)
elif GPU:
    add("resources", "GPUs", "!!", "requested (--nv) but nvidia-smi lists none inside the container")
else:
    add("resources", "GPUs", "", "none visible on this node")
GPU_USE_ROW = len(ROWS)
add("resources", "GPU use", "", "(filled in after the checks)")
for path, label in (("/workspace", os.environ.get("SMOKE_WORKDIR_HOST", "")), ("/scratch", os.environ.get("SMOKE_SCRATCH_HOST", ""))):
    try:
        du = shutil.disk_usage(path)
        add("resources", path, "", f"{human(du.free)} free of {human(du.total)}  <- {label}  ({'writable' if os.access(path, os.W_OK) else 'READ-ONLY'})")
    except Exception as e:
        add("resources", path, "!!", f"not usable: {e}")
add("resources", "HOME", "", f"{os.path.expanduser('~')} (private, {'writable' if os.access(os.path.expanduser('~'), os.W_OK) else 'NOT writable'})")

# ---------------------------------------------------------------- image features
def feature(section, name, fn):
    t = time.time()
    try:
        status, detail = fn()
    except Exception as e:   # noqa: BLE001
        status, detail = "!!", f"{type(e).__name__}: {str(e).splitlines()[0][:160]}"
    add(section, name, status, detail, time.time() - t)
    return status

def f_core():
    assert sys.executable == "/opt/venv/bin/python", f"unexpected python: {sys.executable}"
    assert os.environ.get("PYTHONNOUSERSITE") == "1", "PYTHONNOUSERSITE is not set"
    mods = ["numpy", "pandas", "scipy", "anndata", "scanpy", "mudata", "sklearn", "torch", "lightning", "pyro", "scvi",
            "scib_metrics", "jax", "jaxlib", "flax", "optax", "numpyro", "umap", "leidenalg", "igraph", "matplotlib",
            "seaborn", "h5py", "yaml", "rich", "tqdm", "reportlab"]
    for m in mods: importlib.import_module(m)
    import torch, scvi, scib_metrics, scanpy, anndata, jax
    if not torch.__version__.startswith("2.9.1"): FATAL.append(f"torch {torch.__version__}")
    return "OK", (f"python {sys.version.split()[0]}; torch {torch.__version__}, scvi-tools {scvi.__version__}, scib-metrics {scib_metrics.__version__}, "
                  f"scanpy {ver('scanpy')}, anndata {ver('anndata')}, jax {jax.__version__}, numpy {ver('numpy')}, pandas {ver('pandas')} — {len(mods)} modules import")

MIN_CC = (7, 0)   # oldest compute capability with kernels in the image's torch and RAPIDS builds (sm_70+; the Mamba kernels need 7.5+)

def f_torch_gpu():
    import torch
    if not GPU: return "--", "not used (no GPU / --no-gpu); torch runs on CPU"
    assert torch.cuda.is_available(), "torch.cuda.is_available() is False although --nv was passed"
    n = torch.cuda.device_count()
    too_old = [(i, torch.cuda.get_device_name(i), torch.cuda.get_device_capability(i)) for i in range(n) if torch.cuda.get_device_capability(i) < MIN_CC]
    if too_old:
        i, name, cc = too_old[0]
        raise RuntimeError(f"{name} has compute capability {cc[0]}.{cc[1]}; the image's torch/RAPIDS kernels need {MIN_CC[0]}.{MIN_CC[1]}+ (Volta/T4 or newer; "
                           f"Mamba needs 7.5+): request a newer GPU (another partition or --sbatch-arg=--constraint=...) or run with --no-gpu")
    x = torch.randn(512, 512, device="cuda"); y = (x @ x).sum().item(); torch.cuda.synchronize()
    return "OK", f"{n} device(s): {torch.cuda.get_device_name(0)} (cc {'.'.join(map(str, torch.cuda.get_device_capability(0)))}); cuda {torch.version.cuda}, cudnn {torch.backends.cudnn.version()}; matmul ok ({y:.3g})"

def f_jax_gpu():
    import jax, jax.numpy as jnp
    devs = jax.devices()
    if not GPU: return "--", f"not used; jax devices: {[d.platform for d in devs]}"
    assert any(d.platform == "gpu" for d in devs), f"no GPU device in jax: {devs}"
    v = float(jnp.ones((256, 256)).sum())
    return "OK", f"{len([d for d in devs if d.platform == 'gpu'])} GPU device(s) {devs[0].device_kind}; reduction ok ({v:.0f})"

def f_cupy():
    import cupy as cp
    if not GPU: return "--", f"cupy {cp.__version__} importable; not exercised (no GPU)"
    v = int(cp.arange(1000).sum().get())
    return "OK", f"cupy {cp.__version__}; kernel ok ({v})"

def f_rapids():
    import cudf, cuml, cugraph, rmm, rapids_singlecell as rsc
    vs = f"cudf {cudf.__version__}, cuml {cuml.__version__}, cugraph {cugraph.__version__}, rmm {rmm.__version__}, rapids_singlecell {rsc.__version__}"
    if not GPU: return "--", vs + "; importable, GPU paths not exercised (no GPU)"
    import numpy as np
    from cuml.decomposition import PCA
    s = float(cudf.DataFrame({"a": [1, 2, 3]}).a.sum())
    PCA(n_components=2).fit(np.random.default_rng(0).normal(size=(200, 10)).astype("float32"))
    return "OK", vs + f"; cudf sum ok ({s:.0f}), cuml PCA ok"

def f_mamba():
    import mamba_ssm, causal_conv1d
    from mamba_ssm import Mamba3   # noqa: F401  (the class cell_tools' EncoderHybridMamba uses)
    vs = f"mamba-ssm {mamba_ssm.__version__}, causal-conv1d {causal_conv1d.__version__}"
    if not GPU: return "--", vs + "; importable (Mamba3 class), CUDA kernels not loaded (no GPU)"
    import selective_scan_cuda, causal_conv1d_cuda   # noqa: F401  loads the compiled kernels against this driver
    import torch
    cc = "sm_%d%d" % torch.cuda.get_device_capability(0)
    note = ""
    so = getattr(selective_scan_cuda, "__file__", "")
    if so and shutil.which("cuobjdump"):
        rc, out = sh(f"cuobjdump --list-elf {so}", 60)
        archs = sorted(set(re.findall(r"sm_\d+", out)), key=lambda a: int(a[3:]))
        major = cc[:4]
        ok = any(a[:4] == major and int(a[3:]) <= int(cc[3:]) for a in archs)
        note = f"; kernels for {' '.join(archs)}" + ("" if ok else f" — NO cubin for this GPU ({cc}); Mamba layers would fail")
        if not ok: return "!!", vs + note
    return "OK", vs + f"; CUDA kernels load, GPU {cc}" + note

def f_deepspeed():
    import logging; logging.getLogger("DeepSpeed").setLevel(logging.ERROR)
    import deepspeed
    from deepspeed.moe.layer import MoE   # noqa: F401
    return "OK", f"deepspeed {deepspeed.__version__} (ops are JIT-compiled on first use into TORCH_EXTENSIONS_DIR)"

def f_lora():
    import minlora   # noqa: F401
    return "OK", f"minlora {ver('minlora') or 'git'} (the [lora] extra)"

def f_legacy():
    mods = ["fpdf", "ot", "geomloss", "fastcluster", "panel", "plottable", "jaro", "pytz", "requests", "PIL", "IPython"]
    for m in mods: importlib.import_module(m)
    return "OK", f"{', '.join(mods)} (legacy/ scripts)"

def f_tooling():
    import jupyterlab, papermill, nbformat, nbconvert, pytest   # noqa: F401
    rc, out = sh("jupyter lab --version", 60)
    return "OK", f"jupyterlab {jupyterlab.__version__} (jupyter lab --version -> {out.strip() or rc}), papermill {papermill.__version__}, pytest {pytest.__version__}"

def f_cli_tools():
    out = []
    for name in ("uv", "node", "openspec"):
        rc, o = sh(f"{name} --version", 60)
        if rc != 0 or not o.strip():
            return "!!", f"{name} is not in this image (built before 2026-10-08?) — rebuild from cell_eval.def; " + "; ".join(out)
        out.append(f"{name} {o.strip().splitlines()[0][:40]}")
    return "OK", ", ".join(out) + " (in the image; uv caches under /scratch/.start_singularity/uv)"

def f_cell_tools():
    repo = os.environ.get("CELL_TOOLS_REPO", "")
    if not repo or not os.path.isdir(repo): return "--", "CELL_TOOLS_REPO not set (no capsule-3642729/cell_tools under /workspace)"
    sys.path.insert(0, repo)
    import cell_tools   # noqa: F401
    ok_eval = os.path.isdir(os.path.join(repo, "cell_tools", "evaluation"))
    return "OK", f"import cell_tools from {repo}" + ("; cell_tools/evaluation present" if ok_eval else "; cell_tools/evaluation MISSING")

FEATURES = {"core": f_core, "torch GPU": f_torch_gpu, "jax GPU": f_jax_gpu, "cupy": f_cupy, "RAPIDS": f_rapids,
            "Mamba-3": f_mamba, "DeepSpeed": f_deepspeed, "LoRA": f_lora, "legacy": f_legacy,
            "Jupyter/tools": f_tooling, "CLI tools": f_cli_tools, "cell_tools": f_cell_tools}
# independent groups run in parallel worker processes (forked before any heavy import), so the wall time is
# roughly that of the slowest group (the core imports) instead of the sum
GROUPS = [["core"], ["torch GPU", "jax GPU", "cupy"], ["RAPIDS"], ["Mamba-3", "DeepSpeed"], ["LoRA", "legacy", "Jupyter/tools", "CLI tools", "cell_tools"]]

def run_group(names):
    out = []
    for n in names:
        t = time.time()
        try:
            st, det = FEATURES[n]()
        except BaseException as e:   # noqa: BLE001
            st, det = "!!", f"{type(e).__name__}: {str(e).splitlines()[0][:160] if str(e) else ''}"
        out.append((n, st, det, time.time() - t))
    return out

RESULTS = {}
try:
    import concurrent.futures as cf, multiprocessing as mp
    with cf.ProcessPoolExecutor(max_workers=len(GROUPS), mp_context=mp.get_context("fork")) as ex:
        futs = {ex.submit(run_group, g): g for g in GROUPS}
        for fut in cf.as_completed(futs):
            try:
                for n, st, det, t in fut.result(): RESULTS[n] = (st, det, t)
            except Exception as e:   # noqa: BLE001  (a worker died, e.g. a segfault in a CUDA library)
                for n in futs[fut]: RESULTS[n] = ("!!", f"check process crashed: {type(e).__name__}: {str(e)[:120]}", 0)
except Exception as e:   # noqa: BLE001  no fork / pool unavailable: run sequentially
    for g in GROUPS:
        for n, st, det, t in run_group(g): RESULTS.setdefault(n, (st, det, t))
for n in FEATURES:
    st, det, t = RESULTS.get(n, ("!!", "no result", 0))
    add("image features", n, st, det, t)
    if st == "!!" and n == "core": FATAL.append(n)
    if st == "!!" and GPU and n in ("torch GPU", "jax GPU"): FATAL.append(n)

gpu_users = {"torch GPU": "torch", "jax GPU": "jax", "cupy": "cupy", "RAPIDS": "RAPIDS", "Mamba-3": "Mamba/causal-conv1d kernels"}
if GPU:
    ok = [v for k, v in gpu_users.items() if RESULTS.get(k, ("!!",))[0] == "OK"]
    bad = [v for k, v in gpu_users.items() if RESULTS.get(k, ("!!",))[0] != "OK"]
    use = ("used by " + ", ".join(ok) if ok else "NOT usable by any component") + (f"; failing: {', '.join(bad)}" if bad else "")
else:
    use = "not used (no GPU / --no-gpu): GPU components are import-checked only, jax and DeepSpeed run on CPU"
ROWS[GPU_USE_ROW] = ("resources", "GPU use", "", use, None)

# ---------------------------------------------------------------- host tools bound into the container
def tool(name, env, cmd, extra=None):
    raw = os.environ.get(env, "absent|unknown")
    status, note = raw.split("|", 1) if "|" in raw else (raw, "")
    t = time.time()
    if status != "bound":
        add("host tools", name, "--", ("not bound: " if status == "absent" else "") + note, 0); return
    rc, out = sh(cmd, 60)
    first = out.splitlines()[0][:120] if out else "(no output)"
    if rc != 0:
        add("host tools", name, "!!", f"bound but failing: {first}", time.time() - t); return
    detail = first
    if extra:
        rc2, out2 = sh(extra, 60)
        if rc2 == 0: detail += f"; {out2.strip()[:100]}"
    add("host tools", name, "OK", detail + (f"  [{note}]" if note and len(note) < 90 else ""), time.time() - t)

tool("SLURM", "SMOKE_SLURM", "sbatch --version", "squeue -u \"$USER\" -h 2>/dev/null | wc -l | xargs printf '%s job(s) of yours in the queue'")
tool("ssh", "SMOKE_SSH", "ssh -V 2>&1")
add("host tools", "git", "OK", sh("git --version")[1] + " (in the image)", 0)
tool("gh", "SMOKE_GH", "gh --version | head -1")
tool("Claude Code", "SMOKE_CLAUDE", "claude --version")
tool("Codex", "SMOKE_CODEX", "codex --version")
tool("Antigravity", "SMOKE_AGY", "agy --version 2>&1 || antigravity --version 2>&1")
for line in os.environ.get("SMOKE_EXTRA_TOOLS", "").splitlines():
    parts = line.split("|", 2)
    if len(parts) == 3:
        os.environ["SMOKE_X_" + parts[0]] = f"{parts[1]}|{parts[2]}"
        tool(parts[0], "SMOKE_X_" + parts[0], f"{parts[0]} --version 2>&1 || {parts[0]} --help 2>&1 | head -1")
staged = os.environ.get("SMOKE_STAGED_LIBS", "").strip()
add("host tools", "staged libs", "", staged or "none needed (the image already has every library the bound tools use)")

# ---------------------------------------------------------------- print
W = 15
print("----------------------------------------------------------------")
print(f"smoke test  (image {os.path.basename(os.environ.get('SMOKE_IMAGE', ''))}; mode {os.environ.get('SMOKE_MODE', '')})")
for section in ("resources", "image features", "host tools"):
    print(f"{section}")
    for sec, name, st, detail, t in ROWS:
        if sec != section: continue
        mark = f"[{st}]" if st else "    "
        tt = f"  {t:4.1f}s" if t is not None and t >= 0.05 else ""
        print(f"  {mark} {name:<{W}} {detail}{tt}")
n_ok = sum(1 for r in ROWS if r[2] == "OK"); n_skip = sum(1 for r in ROWS if r[2] == "--"); n_bad = sum(1 for r in ROWS if r[2] == "!!")
print(f"summary: {n_ok} OK, {n_skip} not used / not bound, {n_bad} failed — {time.time() - T0:.1f} s")
print("legend : [OK] works here   [--] not used, not available or import-only   [!!] failed")
print("----------------------------------------------------------------")
if FATAL:
    print("FATAL smoke-test failures:", ", ".join(FATAL), file=sys.stderr); sys.exit(1)
PY
}
if [[ "${RUN_SMOKE}" == 1 || "${MODE}" == check ]]; then
    smoke_rc=0; run_smoke_tests || smoke_rc=$?
    case "${smoke_rc}" in
        0) ;;
        135|137|139) fatal "the check process was killed (exit ${smoke_rc}: bus error / SIGKILL / segfault). On SLURM this almost always means the job's memory limit is too small for the imports (current: ${RES_MEM}); ask for at least 8G, e.g. --mem 64G" ;;
        *) fatal "the smoke test failed (see above); use --no-smoke to start anyway" ;;
    esac
fi
[[ "${MODE}" == check ]] && exit 0

# --------------------------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------------------------
case "${MODE}" in
    shell)
        [[ -t 0 ]] || fatal "shell mode needs a terminal (use 'exec -- cmd' in batch jobs)"
        info "entering /workspace; exit the shell to remove the temporary HOME"
        container_exec /bin/bash --login -i
        ;;
    exec)
        container_exec "${CMD[@]}"
        ;;
    claude)
        [[ "${CLAUDE_BOUND}" == 1 ]] || fatal "claude is not available on this host (see the banner)"
        if [[ -t 0 ]]; then
            container_exec claude ${CMD[@]+"${CMD[@]}"}
        else   # batch job: give the TUI a pseudo-terminal
            quoted=""; for a in ${CMD[@]+"${CMD[@]}"}; do quoted+=" $(printf '%q' "${a}")"; done
            container_exec script -qefc "claude${quoted}" /dev/null
        fi
        ;;
    jupyter)
        jupyter_update_status running
        container_exec jupyter lab --ip=0.0.0.0 --no-browser --port="${PORT}" --port-retries=0 \
            --ServerApp.token="${TOKEN}" --ServerApp.password='' --ServerApp.open_browser=False \
            --ServerApp.allow_remote_access=True --ServerApp.root_dir="${NOTEBOOK_DIR}" \
            ${JUPYTER_ARGS[@]+"${JUPYTER_ARGS[@]}"}
        ;;
esac
