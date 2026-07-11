# Bash completion for the `ws` workshop CLI. Sourced from the attendee terminal's .bashrc
# (gitops/workshop-config/templates/showroom.yaml terminal-prep). Tab completes subcommands,
# then module ids (from the cloned repo's entry states) or flags. (project-owner ask 2026-07-11.)
_ws_complete() {
  local cur prev subcmds mods repo
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcmds="list prep verify reset start solve git-refresh doctor"

  # First word after `ws` → a subcommand.
  if [ "$COMP_CWORD" -eq 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$subcmds" -- "$cur")
    return
  fi

  # After a module-taking verb → complete module ids from the repo's entry states.
  case "$prev" in
    prep|verify|reset|start|solve)
      repo="${WS_REPO_ROOT:-$HOME/ocp-getting-started}"
      mods="$(ls -d "$repo"/gitops/entry-states/m[0-9]* 2>/dev/null | while read -r d; do basename "$d"; done)"
      [ -z "$mods" ] && mods="m01 m02 m03 m04 m05 m06 m07 m08 m09 m10 m11 m12 m13"
      mapfile -t COMPREPLY < <(compgen -W "$mods" -- "$cur")
      return
      ;;
  esac

  # Otherwise offer the common flags.
  mapfile -t COMPREPLY < <(compgen -W "--user --yes" -- "$cur")
}
complete -F _ws_complete ws
