# Rust/Cargo environment (if installed).
[[ -r "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"

case ":$PATH:" in
  *":$HOME/.bun/bin:"*) ;;
  *) export PATH="$HOME/.bun/bin:$PATH" ;;
esac
