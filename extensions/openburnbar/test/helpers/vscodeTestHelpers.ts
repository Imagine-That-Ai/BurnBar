import * as vscode from 'vscode';

export function themeIconId(iconPath: vscode.IconPath | undefined): string {
  if (iconPath instanceof vscode.ThemeIcon) {
    return iconPath.id;
  }
  throw new Error(`Expected ThemeIcon, received ${String(iconPath)}`);
}
