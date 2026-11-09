# WebTabinal zsh integration v2
# Guard: only active inside WebTabinal sessions
[[ -z "$WEBTABINAL_SESSION_ID" ]] && return
[[ -n "$WEBTABINAL_INTEGRATION_LOADED" ]] && return
WEBTABINAL_INTEGRATION_LOADED=1

__webtabinal_osc() {
  printf '\033]%s\033\\' "$1"
}

__webtabinal_cwd() {
  emulate -L zsh -o extendedglob
  local LC_ALL=C
  local encoded="${PWD//(#m)[^a-zA-Z0-9._~\/-]/%${(l:2::0:)$(([##16]#MATCH))}}"
  __webtabinal_osc "7;file://${encoded}"
}

__webtabinal_precmd() {
  local code=$?
  __webtabinal_osc "133;D;${code}"
  __webtabinal_cwd
  __webtabinal_osc "133;A"
}

__webtabinal_preexec() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  __webtabinal_osc "9973;cmd;${b64}"
  __webtabinal_osc "133;C"
}

# Announce that the shell is terminating on its own. `exit` and Ctrl+D return
# the last command's status, so the daemon cannot tell a user-requested exit
# from a crash by status alone; this signal is what distinguishes them.
__webtabinal_zshexit() {
  local code=$?
  [[ -n "$__webtabinal_exit_sent" ]] && return
  __webtabinal_exit_sent=1
  __webtabinal_osc "9973;exit;${code}"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __webtabinal_precmd
add-zsh-hook preexec __webtabinal_preexec
add-zsh-hook chpwd __webtabinal_cwd
# add-zsh-hook folds any zshexit function the user's rc already defined into
# zshexit_functions, so both run.
add-zsh-hook zshexit __webtabinal_zshexit

# Initial CWD
__webtabinal_cwd
