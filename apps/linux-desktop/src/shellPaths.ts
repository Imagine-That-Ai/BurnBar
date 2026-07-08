export function displayLinuxSupportDir(home = '~'): string {
  return `${home}/.local/share/openburnbar`;
}

export function displayLinuxSocketPath(home = '~'): string {
  return '$XDG_RUNTIME_DIR/openburnbar/daemon.sock';
}

export function displayLinuxConfigDir(home = '~'): string {
  return `${home}/.config/openburnbar`;
}
