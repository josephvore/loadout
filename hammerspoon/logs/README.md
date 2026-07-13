# Hammerspoon Logs

Hammerspoon modules write local runtime logs here:

- `init.log`
- `dictation.log`
- `refine.log`
- `flows.log`
- `shortcuts.log`
- `quickshots.log`

The `*.log` files are gitignored because they can contain local app names,
errors, and short transcript samples. Agents should inspect these files first
when debugging Hammerspoon behavior.

Useful commands:

```sh
tail -n 80 ~/dotfiles/hammerspoon/logs/dictation.log
tail -f ~/dotfiles/hammerspoon/logs/init.log
```
