export function stripFirebaseRulesLineComment(line) {
  let output = "";
  let quote = null;
  let escaped = false;

  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    const nextCharacter = line[index + 1];

    if (quote) {
      output += character;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }

    if (character === "\"" || character === "'") {
      quote = character;
      output += character;
      continue;
    }

    if (character === "/" && nextCharacter === "/") {
      break;
    }

    output += character;
  }

  return output;
}

export function compactFirebaseRulesSource(source) {
  const compactedLines = source
    .split(/\r?\n/)
    .map(stripFirebaseRulesLineComment)
    .map((line) => line.trim())
    .filter(Boolean);

  return `${compactedLines.join("\n")}\n`;
}

export function rulesSourceForDeploy(fileName, source) {
  return fileName === "firestore.rules"
    ? compactFirebaseRulesSource(source)
    : source;
}
