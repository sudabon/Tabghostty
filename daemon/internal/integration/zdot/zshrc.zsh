# WebTabinal ZDOTDIR proxy: user's .zshrc, then load OSC integration.
if [[ -n "${WEBTABINAL_ZSHRC_LOADED:-}" ]]; then
  ZDOTDIR=${USER_ZDOTDIR:-$ZDOTDIR}
  return
fi
WEBTABINAL_ZSHRC_LOADED=1

if [[ "${WEBTABINAL_INJECTION:-}" == "1" ]]; then
  HISTFILE=${USER_ZDOTDIR:-$HOME}/.zsh_history
fi

if [[ "${WEBTABINAL_INJECTION:-}" == "1" && -o rcs && -n "${USER_ZDOTDIR:-}" && -f "$USER_ZDOTDIR/.zshrc" ]]; then
  WEBTABINAL_ZDOTDIR=$ZDOTDIR
  ZDOTDIR=$USER_ZDOTDIR
  . "$USER_ZDOTDIR/.zshrc"
  ZDOTDIR=$WEBTABINAL_ZDOTDIR
fi

if [[ -n "${WEBTABINAL_SESSION_ID:-}" && -n "${WEBTABINAL_INTEGRATION_PATH:-}" && -f "$WEBTABINAL_INTEGRATION_PATH" ]]; then
  . "$WEBTABINAL_INTEGRATION_PATH"
fi

# Login shells still need our .zlogin; restore ZDOTDIR afterwards there.
if [[ ! -o login && -n "${USER_ZDOTDIR:-}" ]]; then
  ZDOTDIR=$USER_ZDOTDIR
fi
