#!/usr/bin/env zsh
# claude-agent-monitor.sh
# Launches a zellij session with one pane per Claude Code agent.
# Each agent pane is split into 4 sub-panes:
#   💬 JSONL conversation tail
#   📁 File system changes (fswatch)
#   ⚙  Shell commands (dtrace or pgrep polling)
#   🔀 Git activity
#
# Usage (from any directory):
#   claude_agent_monitor .                  # watch cwd, auto-detect agents
#   claude_agent_monitor /path/to/project   # explicit project dir
#   claude_agent_monitor . agent1 agent2    # explicit agent names

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
AGENTS_DIR="$CLAUDE_DIR/agents"
PROJECTS_DIR="$CLAUDE_DIR/projects"
SESSION_NAME="${ZELLIJ_SESSION:-claude-agents}"
WATCH_DIR="${1:-.}"
shift 2>/dev/null || true                   # rest = optional explicit agent names
WATCH_DIR=$(cd "$WATCH_DIR" && pwd)         # resolve to absolute path
JSONL_LINES="${JSONL_LINES:-40}"
REFRESH_GIT="${REFRESH_GIT:-3}"

RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
die()  { printf "${RED}ERROR: %s${RESET}\n" "$*" >&2; exit 1; }
info() { printf "${CYAN}▶ %s${RESET}\n" "$*"; }

# ── Resolve agents from ~/.claude/agents/*.md ─────────────────────────────────
resolve_agents() {
  if [[ $# -gt 0 ]]; then
    print -l -- "$@"
    return
  fi
  if [[ -d "$AGENTS_DIR" ]]; then
    local f agents=()
    for f in "$AGENTS_DIR"/*.md(N); do
      agents+=("${f:t:r}")    # :t = filename only, :r = strip extension
    done
    if [[ ${#agents[@]} -gt 0 ]]; then
      print -l -- "${agents[@]}"
      return
    fi
  fi
  die "No agents found in $AGENTS_DIR — pass agent names explicitly."
}

# ── Find the most-recently-modified JSONL that mentions the agent ─────────────
latest_jsonl() {
  local agent="$1" match=""
  if [[ -d "$PROJECTS_DIR" ]]; then
    match=$(
      find "$PROJECTS_DIR" -name "*.jsonl" -print0 2>/dev/null \
        | xargs -0 grep -l "\"${agent}\"" 2>/dev/null \
        | xargs ls -t 2>/dev/null \
        | head -1
    )
  fi
  # Fall back to newest JSONL overall
  if [[ -z "$match" && -d "$PROJECTS_DIR" ]]; then
    match=$(find "$PROJECTS_DIR" -name "*.jsonl" -print0 2>/dev/null \
              | xargs -0 ls -t 2>/dev/null | head -1)
  fi
  printf '%s' "$match"
}

# ── Shell payload that runs inside each agent pane ────────────────────────────
# Written as a self-contained bash heredoc so zellij can spawn it cleanly.
# macOS-specific choices:
#   - fswatch instead of inotifywait
#   - ps -p instead of /proc
#   - dtrace for full syscall tracing (needs sudo), pgrep polling as fallback
#   - sed -l for line-buffered output (BSD sed flag)
#   - git -C <dir> instead of cd to avoid subshell issues
pane_cmd() {
  local agent="$1"
  local jsonl
  jsonl=$(latest_jsonl "$agent")

  cat <<BASH
bash <<'INNER'
AGENT='${agent}'
JSONL='${jsonl}'
WATCH_DIR='${WATCH_DIR}'
REFRESH_GIT='${REFRESH_GIT}'
JSONL_LINES='${JSONL_LINES}'

print_header() {
  printf "\n\${2}━━━━━━  \${1}  [agent: \${AGENT}]  ━━━━━━\033[0m\n"
}

# ── 💬 Conversation log ───────────────────────────────────────────────────────
watch_jsonl() {
  print_header '💬 CONVERSATION' '\033[0;36m'
  if [[ -z "\$JSONL" || ! -f "\$JSONL" ]]; then
    printf '⚠  No session log yet — waiting...\n'
    while [[ ! -f "\$JSONL" ]]; do sleep 2; done
  fi
  tail -n "\$JSONL_LINES" -f "\$JSONL" 2>/dev/null | while IFS= read -r line; do
    role=\$(python3 -c "
import sys, json
try:    print(json.loads(sys.argv[1]).get('role','?'))
except: print('?')
" "\$line" 2>/dev/null)
    text=\$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    c = d.get('message', {}).get('content', d.get('content', ''))
    if isinstance(c, list):
        print(' '.join(x.get('text','') for x in c if isinstance(x,dict))[:200])
    elif isinstance(c, str):
        print(c[:200])
except:
    print('')
" "\$line" 2>/dev/null)
    case "\$role" in
      user)      printf '\033[1;32m[user]\033[0m %s\n'   "\$text" ;;
      assistant) printf '\033[1;34m[claude]\033[0m %s\n' "\$text" ;;
      *)         printf '\033[0;90m[%s]\033[0m %s\n'     "\$role" "\$text" ;;
    esac
  done
}

# ── 📁 File-system changes ────────────────────────────────────────────────────
watch_fs() {
  print_header '📁 FILE CHANGES' '\033[0;33m'
  if command -v fswatch >/dev/null 2>&1; then
    fswatch \
      --recursive \
      --event-flags \
      --exclude='\.git/index' \
      --exclude='\.git/COMMIT_EDITMSG' \
      --exclude='\.git/objects' \
      "\$WATCH_DIR" 2>/dev/null \
    | while IFS= read -r evt; do
        printf '%s  %s\n' "\$(date +%H:%M:%S)" "\$evt"
      done
  else
    printf '⚠  fswatch not found — run: brew install fswatch\n'
    sleep infinity
  fi
}

# ── ⚙  Shell commands ─────────────────────────────────────────────────────────
# Primary: dtrace execve tracing (requires SIP-disabled or passwordless sudo).
# Fallback: poll pgrep for new children of claude processes using ps on macOS.
watch_shell() {
  print_header '⚙  SHELL COMMANDS' '\033[0;35m'
  if sudo -n true >/dev/null 2>&1; then
    printf 'ℹ  Using dtrace (sudo available)\n\n'
    sudo dtrace -q -n '
      syscall::execve:entry {
        printf("%Y  [pid %d]  %s\n", walltimestamp, pid, copyinstr(arg0));
      }
    ' 2>/dev/null
  else
    printf 'ℹ  Polling Claude child processes via pgrep + ps\n'
    printf 'ℹ  For full coverage: sudo visudo → add NOPASSWD: /usr/sbin/dtrace\n\n'
    declare -A seen
    while true; do
      while IFS= read -r pid; do
        # Get direct children on macOS using pgrep -P
        while IFS= read -r child; do
          [[ -z "\$child" ]] && continue
          if [[ -z "\${seen[\$child]:-}" ]]; then
            seen[\$child]=1
            cmd=\$(ps -p "\$child" -o args= 2>/dev/null || true)
            [[ -n "\$cmd" ]] && printf '%s  [pid %s]  %s\n' "\$(date +%H:%M:%S)" "\$child" "\$cmd"
          fi
        done < <(pgrep -P "\$pid" 2>/dev/null || true)
      done < <(pgrep -f 'claude' 2>/dev/null || true)
      sleep 1
    done
  fi
}

# ── 🔀 Git activity ───────────────────────────────────────────────────────────
watch_git() {
  print_header '🔀 GIT' '\033[0;32m'
  if ! git -C "\$WATCH_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    printf '⚠  Not a git repo: %s\n' "\$WATCH_DIR"
    sleep infinity
    return
  fi
  local prev=""
  while true; do
    local log diff status
    log=\$(    git -C "\$WATCH_DIR" log    --oneline --all -15 2>/dev/null || true)
    diff=\$(   git -C "\$WATCH_DIR" diff   --stat HEAD         2>/dev/null || true)
    status=\$( git -C "\$WATCH_DIR" status --short             2>/dev/null || true)
    local cur="\${log}\${diff}\${status}"
    if [[ "\$cur" != "\$prev" ]]; then
      clear
      print_header '🔀 GIT' '\033[0;32m'
      printf '\033[1mRecent commits:\033[0m\n%s\n\n'    "\$log"
      printf '\033[1mDiff stat (HEAD):\033[0m\n%s\n\n' "\$diff"
      printf '\033[1mWorking tree:\033[0m\n%s\n'        "\$status"
      prev="\$cur"
    fi
    sleep "\$REFRESH_GIT"
  done
}

# ── Launch: sub-panes inside zellij, or prefixed stdout outside ───────────────
if [[ -n "\${ZELLIJ:-}" ]]; then
  watch_jsonl &

  zellij action new-pane --direction down -- bash -c "
    WATCH_DIR='\$WATCH_DIR'
    $(declare -f print_header watch_fs)
    watch_fs"

  zellij action new-pane --direction right -- bash -c "
    AGENT='\$AGENT'
    $(declare -f print_header watch_shell)
    watch_shell"

  zellij action new-pane --direction down -- bash -c "
    WATCH_DIR='\$WATCH_DIR'; REFRESH_GIT='\$REFRESH_GIT'
    $(declare -f print_header watch_git)
    watch_git"

  wait
else
  watch_jsonl 2>&1 | sed -l 's/^/[CONV ] /' &
  watch_fs    2>&1 | sed -l 's/^/[FS   ] /' &
  watch_shell 2>&1 | sed -l 's/^/[SHELL] /' &
  watch_git   2>&1 | sed -l 's/^/[GIT  ] /' &
  wait
fi
INNER
BASH
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  command -v zellij  >/dev/null 2>&1 || die "zellij not found  → brew install zellij"
  command -v python3 >/dev/null 2>&1 || die "python3 not found → brew install python"
  command -v fswatch >/dev/null 2>&1 \
    || info "fswatch not found → brew install fswatch  (needed for file watching)"

  local -a agents
  while IFS= read -r a; do agents+=("$a"); done < <(resolve_agents "$@")

  info "Agents    : ${agents[*]}"
  info "Watch dir : $WATCH_DIR"
  info "Session   : $SESSION_NAME"

  local layout_file
  layout_file=$(mktemp "${TMPDIR:-/tmp}/claude-layout-XXXXXX.kdl")
  trap 'rm -f "$layout_file"' EXIT

  {
    printf 'layout {\n'
    for agent in "${agents[@]}"; do
      local raw escaped
      raw=$(pane_cmd "$agent")
      escaped=${raw//\\/\\\\}
      escaped=${escaped//\"/\\\"}
      printf '    pane name="%s" {\n'        "$agent"
      printf '        command "bash"\n'
      printf '        args "-c" "%s"\n'      "$escaped"
      printf '    }\n'
    done
    printf '}\n'
  } > "$layout_file"

  if zellij list-sessions 2>/dev/null | grep -qF "$SESSION_NAME"; then
    info "Session '$SESSION_NAME' already exists — attaching..."
    exec zellij attach "$SESSION_NAME"
  else
    exec zellij --session "$SESSION_NAME" --layout "$layout_file"
  fi
}

main "$@"
