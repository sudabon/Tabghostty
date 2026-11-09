# WebTabinal ZDOTDIR proxy: user's .zlogin, then restore ZDOTDIR.
if [[ -n "${USER_ZDOTDIR:-}" && -f "$USER_ZDOTDIR/.zlogin" ]]; then
  WEBTABINAL_ZDOTDIR=$ZDOTDIR
  ZDOTDIR=$USER_ZDOTDIR
  . "$USER_ZDOTDIR/.zlogin"
  ZDOTDIR=$WEBTABINAL_ZDOTDIR
fi
if [[ -n "${USER_ZDOTDIR:-}" ]]; then
  ZDOTDIR=$USER_ZDOTDIR
fi
