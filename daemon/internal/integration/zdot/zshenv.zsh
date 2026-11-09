# WebTabinal ZDOTDIR proxy: user's .zshenv, then restore our ZDOTDIR.
if [[ -n "${USER_ZDOTDIR:-}" && -f "$USER_ZDOTDIR/.zshenv" ]]; then
  WEBTABINAL_ZDOTDIR=$ZDOTDIR
  ZDOTDIR=$USER_ZDOTDIR
  if [[ $USER_ZDOTDIR != $WEBTABINAL_ZDOTDIR ]]; then
    . "$USER_ZDOTDIR/.zshenv"
  fi
  USER_ZDOTDIR=$ZDOTDIR
  ZDOTDIR=$WEBTABINAL_ZDOTDIR
fi
