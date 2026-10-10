# ----- Performance: Cached Homebrew prefix -----
# Cache this to avoid running `brew --prefix` on every shell startup (~40ms savings)
if [[ -z "$BREW_PREFIX" ]]; then
  if [[ -n "$HOMEBREW_PREFIX" ]]; then
    export BREW_PREFIX="$HOMEBREW_PREFIX"
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    export BREW_PREFIX=/opt/homebrew
  else
    export BREW_PREFIX=/usr/local
  fi
fi

# ----- pyenv (before Oh My Zsh, lazy-loaded for speed) -----
export PYENV_ROOT="$HOME/.pyenv"

# ----- PATH (consolidated, no duplicates) -----
typeset -U path PATH fpath  # Prevent duplicate PATH/fpath entries
export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.bun/bin:$PYENV_ROOT/shims:$PYENV_ROOT/bin:$BREW_PREFIX/bin:/usr/local/bin:$HOME/go/bin:$PATH"

# Lazy-load pyenv (~100ms savings)
if command -v pyenv &>/dev/null; then
  pyenv() {
    unset -f pyenv python python3 pip pip3
    eval "$(command pyenv init - zsh)"
    pyenv "$@"
  }
  python()  { unset -f python;  eval "$(command pyenv init - zsh)"; python "$@"; }
  python3() { unset -f python3; eval "$(command pyenv init - zsh)"; python3 "$@"; }
  pip()     { unset -f pip;     eval "$(command pyenv init - zsh)"; pip "$@"; }
  pip3()    { unset -f pip3;    eval "$(command pyenv init - zsh)"; pip3 "$@"; }
fi

# ----- Oh My Zsh -----
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""

# Completion / behavior
HYPHEN_INSENSITIVE="true"
zstyle ':omz:update' mode auto

# Plugins (removed zsh-completions - see note below)
plugins=(
  git
  zsh-autosuggestions
  copyfile
  web-search
)

# zsh-completions: Add to fpath BEFORE sourcing OMZ (fixes completion loading)
fpath+=("$BREW_PREFIX/share/zsh/site-functions")
[[ -d "$BREW_PREFIX/share/zsh-completions" ]] && fpath+=("$BREW_PREFIX/share/zsh-completions")
[[ -d "$HOME/.zsh/completions" ]] && fpath+=("$HOME/.zsh/completions")

[[ -r "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

# ----- Pure prompt -----
export PURE_CMD_MAX_EXEC_TIME=2
export PURE_GIT_PULL=0
export PURE_GIT_UNTRACKED_DIRTY=1

autoload -U promptinit && promptinit
prompt pure 2>/dev/null  # falls back to the default prompt if Pure isn't installed

# Pure prompt colors (Material Design)
zstyle ':prompt:pure:path' color '#89ddff'
zstyle ':prompt:pure:git:branch' color '#c792ea'
zstyle ':prompt:pure:git:dirty' color '#f07178'
zstyle ':prompt:pure:git:arrow' color '#82aaff'
zstyle ':prompt:pure:prompt:success' color '#c3e88d'
zstyle ':prompt:pure:prompt:error' color '#f07178'

# ----- Editor -----
export EDITOR='vim'

# ----- History -----
HISTSIZE=50000
SAVEHIST=50000
HISTFILE=~/.zsh_history
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY

# ----- Options -----
setopt autocd

# ----- Aliases -----
alias myip="curl -s https://ipv4.icanhazip.com/"
alias zshconfig="$EDITOR ~/.zshrc"
alias ohmyzsh="$EDITOR ~/.oh-my-zsh"
alias ..='cd ..'
alias ...='cd ../..'
alias reload='source ~/.zshrc'
alias ports='lsof -i -P -n | grep LISTEN'
alias gs='git status'
alias gp='git pull'

# eza (modern ls replacement with icons)
if command -v eza &>/dev/null; then
  alias ls='eza --icons --group-directories-first'
  alias ll='eza -la --icons --group-directories-first --git'
  alias lt='eza --tree --level=2 --icons'
  alias la='eza -a --icons --group-directories-first'
fi

# ----- fzf (fuzzy finder) -----
# Use fd instead of find (faster, respects .gitignore)
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'

# Default options with Material Design colors
export FZF_DEFAULT_OPTS='
  --color=bg+:#37474f,bg:#263238,spinner:#82aaff,hl:#89ddff
  --color=fg:#eeffff,header:#546e7a,info:#c3e88d,pointer:#82aaff
  --color=marker:#c3e88d,fg+:#eeffff,prompt:#c792ea,hl+:#82aaff
  --height=40%
  --layout=reverse
  --border=rounded
  --info=inline
  --marker="✓"
  --pointer="▶"
  --prompt="❯ "
  --bind="ctrl-d:half-page-down,ctrl-u:half-page-up"
  --bind="ctrl-y:execute-silent(echo -n {+} | pbcopy)+abort"
'

# Ctrl+T: File search with bat preview
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_CTRL_T_OPTS='
  --preview="bat --style=numbers --color=always --line-range=:500 {}"
  --preview-window=right:50%:wrap
  --bind="ctrl-/:toggle-preview"
'

# Alt+C: Directory search with eza preview
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
export FZF_ALT_C_OPTS='
  --preview="eza --tree --level=2 --icons --color=always {}"
  --preview-window=right:50%:wrap
'

# Ctrl+R: History search
export FZF_CTRL_R_OPTS='
  --preview="echo {}"
  --preview-window=down:3:wrap
'

# Load fzf keybindings and completion only when a real TTY is attached.
if [[ -o interactive && -t 0 && -t 1 ]] && command -v fzf &>/dev/null; then
  source <(fzf --zsh)
fi

# ----- zoxide -----
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

# ----- fnm / pnpm -----
command -v fnm &>/dev/null && eval "$(fnm env --shell zsh --use-on-cd --corepack-enabled)"

# Keep user-level npm globals stable and ahead of fnm's versioned shims.
export PATH="$HOME/.local/bin:$PATH"

# ----- iTerm2 integration -----
# Disabled - was adding extra chevron marks
# [[ -e "${HOME}/.iterm2_shell_integration.zsh" ]] && source "${HOME}/.iterm2_shell_integration.zsh"

# ----- bat theme -----
export BAT_THEME="OneHalfDark"

# ----- Autosuggestions style -----
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#546e7a'

# ----- Completion styling -----
zstyle ':completion:*' menu select
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{red}-- no matches --%f'

# ----- Colored man pages (Material Design) -----
export LESS_TERMCAP_mb=$'\e[1;38;2;130;170;255m'
export LESS_TERMCAP_md=$'\e[1;38;2;130;170;255m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[38;2;255;203;107m'
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[4;38;2;199;146;234m'

# ----- Claude Code optimization -----
export ENABLE_TOOL_SEARCH=auto:5

# ----- Syntax highlighting (MUST be last) -----
[[ -r "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && \
  source "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# Syntax highlighting colors (Material Design)
if (( ${+ZSH_HIGHLIGHT_STYLES} )); then
  ZSH_HIGHLIGHT_STYLES[command]='fg=#c3e88d'
  ZSH_HIGHLIGHT_STYLES[alias]='fg=#c3e88d'
  ZSH_HIGHLIGHT_STYLES[builtin]='fg=#82aaff'
  ZSH_HIGHLIGHT_STYLES[function]='fg=#82aaff'
  ZSH_HIGHLIGHT_STYLES[path]='fg=#89ddff,underline'
  ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=#ffcb6b'
  ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=#ffcb6b'
  ZSH_HIGHLIGHT_STYLES[commandseparator]='fg=#c792ea'
fi

# Claude Code. Append --dangerously-skip-permissions yourself if you want to
# skip per-action approval (convenient, but removes a safety gate).
alias cc='claude'

# direnv (auto-loads .envrc files; e.g. per-project env vars / tokens)
command -v direnv &>/dev/null && eval "$(direnv hook zsh)"

# libpq CLI tools (psql, etc.) on PATH, if installed via Homebrew.
if command -v brew &>/dev/null; then
  _libpq="$(brew --prefix libpq 2>/dev/null)"
  [[ -n "$_libpq" && -d "$_libpq/bin" ]] && export PATH="$_libpq/bin:$PATH"
  unset _libpq
fi

# Machine-specific settings stay outside tracked configuration.
if [[ -r "$HOME/.zshrc.local" ]]; then
  source "$HOME/.zshrc.local"
fi
