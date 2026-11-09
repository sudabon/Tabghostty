# WebTabinal bash integration v2
# Guard: only active inside WebTabinal sessions. bash 3.2 compatible.
[[ -z "$WEBTABINAL_SESSION_ID" ]] && return
[[ -n "$WEBTABINAL_INTEGRATION_LOADED" ]] && return
WEBTABINAL_INTEGRATION_LOADED=1

__webtabinal_osc() {
  printf '\033]%s\033\\' "$1"
}

__webtabinal_cwd() {
  local LC_ALL=C
  local pwd="$PWD"
  local encoded="" i=0 c hex
  local len=${#pwd}
  while [ "$i" -lt "$len" ]; do
    c=${pwd:i:1}
    case "$c" in
      [A-Za-z0-9._~/-]) encoded=$encoded$c ;;
      *)
        printf -v hex '%02X' "'$c"
        encoded=$encoded%$hex
        ;;
    esac
    i=$((i+1))
  done
  __webtabinal_osc "7;file://${encoded}"
}

__webtabinal_prompt() {
  local code=$?
  __webtabinal_in_prompt=1
  if [[ -n "$__webtabinal_cmd_running" ]]; then
    __webtabinal_osc "133;D;${code}"
    __webtabinal_cmd_running=
  fi
  __webtabinal_cwd
  __webtabinal_osc "133;A"
  if [[ -n "$__webtabinal_rest_prompt" ]]; then
    eval "$__webtabinal_rest_prompt"
  fi
  __webtabinal_preexec_ready=1
  __webtabinal_in_prompt=
}

__webtabinal_debug() {
  local ret=$?
  if [[ -n "$__webtabinal_in_prompt" || -n "$COMP_LINE" || -z "$__webtabinal_preexec_ready" ]]; then
    return $ret
  fi
  case "$BASH_COMMAND" in
    __webtabinal_prompt*|__webtabinal_debug*|__webtabinal_cwd*|__webtabinal_osc*)
      return $ret
      ;;
  esac
  if [[ -z "$__webtabinal_cmd_running" ]]; then
    __webtabinal_cmd_running=1
    __webtabinal_preexec_ready=
    local b64
    b64=$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')
    __webtabinal_osc "9973;cmd;${b64}"
    __webtabinal_osc "133;C"
  fi
  if [[ -n "$__webtabinal_prior_debug_cmd" ]]; then
    eval "$__webtabinal_prior_debug_cmd"
  fi
  return $ret
}

__webtabinal_install_prompt() {
  local decl
  decl=$(declare -p PROMPT_COMMAND 2>/dev/null) || decl=
  case "$decl" in
    'declare -a '*|'declare -ax '*)
      local _i _rest=
      for _i in "${PROMPT_COMMAND[@]}"; do
        if [[ "$_i" == __webtabinal_prompt ]]; then
          continue
        fi
        _rest="${_rest}${_i}; "
      done
      __webtabinal_rest_prompt=$_rest
      PROMPT_COMMAND=('__webtabinal_prompt')
      ;;
    *)
      case "${PROMPT_COMMAND-}" in
        __webtabinal_prompt) return ;;
      esac
      __webtabinal_rest_prompt=${PROMPT_COMMAND-}
      PROMPT_COMMAND='__webtabinal_prompt'
      ;;
  esac
}

# Announce that the shell is terminating on its own. `exit` and Ctrl+D return
# the last command's status, so the daemon cannot tell a user-requested exit
# from a crash by status alone; this signal is what distinguishes them.
__webtabinal_setstatus() {
  return $1
}

__webtabinal_atexit() {
  local code=$?
  if [[ -z "$__webtabinal_exit_sent" ]]; then
    __webtabinal_exit_sent=1
    __webtabinal_osc "9973;exit;${code}"
  fi
  if [[ -n "$__webtabinal_prior_exit_cmd" ]]; then
    # Hand the user's trap the status the shell is exiting with.
    eval "__webtabinal_setstatus $code; $__webtabinal_prior_exit_cmd"
  fi
  return $code
}

__webtabinal_prior_exit_cmd=
__wt_exit_trap=$(trap -p EXIT 2>/dev/null) || __wt_exit_trap=
if [[ -n "$__wt_exit_trap" ]]; then
  __wt_exit_trap=${__wt_exit_trap#trap -- \'}
  __wt_exit_trap=${__wt_exit_trap%\' EXIT}
  case "$__wt_exit_trap" in
    *__webtabinal_atexit*) ;;
    *) __webtabinal_prior_exit_cmd=$__wt_exit_trap ;;
  esac
fi
trap '__webtabinal_atexit' EXIT

__webtabinal_prior_debug_cmd=
__wt_trap=$(trap -p DEBUG 2>/dev/null) || __wt_trap=
if [[ -n "$__wt_trap" ]]; then
  __wt_trap=${__wt_trap#trap -- \'}
  __wt_trap=${__wt_trap%\' DEBUG}
  case "$__wt_trap" in
    *__webtabinal_debug*) ;;
    *) __webtabinal_prior_debug_cmd=$__wt_trap ;;
  esac
fi
trap '__webtabinal_debug' DEBUG
__webtabinal_install_prompt

# Initial CWD
__webtabinal_cwd
__webtabinal_preexec_ready=1
