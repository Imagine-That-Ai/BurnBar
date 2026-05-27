import * as vscode from 'vscode';

export function themeIconId(iconPath: vscode.IconPath | undefined): string {
  if (iconPath instanceof vscode.ThemeIcon) {
    return iconPath.id;
  }
  throw new Error(`Expected ThemeIcon, received ${String(iconPath)}`);
}

export function objectIconId(iconPath: vscode.IconPath | undefined): string | undefined {
  if (!iconPath || typeof iconPath !== 'object') {
    return undefined;
  }
  if ('id' in iconPath && typeof iconPath.id === 'string') {
    return iconPath.id;
  }
  return undefined;
}
