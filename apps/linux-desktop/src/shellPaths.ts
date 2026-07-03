export function displayLinuxSupportDir(home = '~'): string {
  return `${home}/.local/share/openburnbar`;
}

export function displayLinuxSocketPath(home = '~'): string {
  return `${displayLinuxSupportDir(home)}/openburnbar-daemon.sock`;
}

export function displayLinuxConfigDir(home = '~'): string {
  return `${home}/.config/openburnbar`;
}