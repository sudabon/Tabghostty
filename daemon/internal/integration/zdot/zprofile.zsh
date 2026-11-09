# WebTabinal ZDOTDIR proxy: user's .zprofile.
if [[ -o login && -n "${USER_ZDOTDIR:-}" && -f "$USER_ZDOTDIR/.zprofile" ]]; then
  WEBTABINAL_ZDOTDIR=$ZDOTDIR
  ZDOTDIR=$USER_ZDOTDIR
  . "$USER_ZDOTDIR/.zprofile"
  ZDOTDIR=$WEBTABINAL_ZDOTDIR
fi
