# Homebrew (Apple Silicon at /opt/homebrew, Intel at /usr/local).
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# OrbStack command-line tools and integration (if installed).
source ~/.orbstack/shell/init.zsh 2>/dev/null || :

# Bun
export PATH="$HOME/.bun/bin:$PATH"

# pyenv (login shells)
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
command -v pyenv &>/dev/null && eval "$(pyenv init --path)"

ulimit -S -n 65536 2>/dev/null || true
