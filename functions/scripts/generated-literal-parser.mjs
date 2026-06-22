import ts from "typescript";

function literalError(message, node) {
  const suffix = node ? ` near '${node.getText().slice(0, 80)}'` : "";
  return new Error(`Unsupported generated literal: ${message}${suffix}`);
}

function propertyName(name) {
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) {
    return name.text;
  }
  throw literalError("object keys must be static identifiers or string literals", name);
}

function numericLiteral(node) {
  const parsed = Number(node.text);
  if (!Number.isFinite(parsed)) {
    throw literalError("numeric literal must be finite", node);
  }
  return parsed;
}

function evaluateLiteral(node) {
  if (ts.isParenthesizedExpression(node)) {
    return evaluateLiteral(node.expression);
  }
  if (ts.isArrayLiteralExpression(node)) {
    return node.elements.map((item) => {
      if (ts.isSpreadElement(item) || item.kind === ts.SyntaxKind.OmittedExpression) {
        throw literalError("array spread and holes are not allowed", item);
      }
      return evaluateLiteral(item);
    });
  }
  if (ts.isObjectLiteralExpression(node)) {
    const object = {};
    for (const property of node.properties) {
      if (!ts.isPropertyAssignment(property)) {
        throw literalError("object literal may contain only property assignments", property);
      }
      Object.defineProperty(object, propertyName(property.name), {
        value: evaluateLiteral(property.initializer),
        enumerable: true,
        configurable: true,
        writable: true,
      });
    }
    return object;
  }
  if (ts.isStringLiteral(node)) {
    return node.text;
  }
  if (ts.isNumericLiteral(node)) {
    return numericLiteral(node);
  }
  if (ts.isPrefixUnaryExpression(node) && ts.isNumericLiteral(node.operand)) {
    const value = numericLiteral(node.operand);
    switch (node.operator) {
      case ts.SyntaxKind.MinusToken:
        return -value;
      case ts.SyntaxKind.PlusToken:
        return value;
      default:
        throw literalError("unsupported numeric unary operator", node);
    }
  }
  if (node.kind === ts.SyntaxKind.TrueKeyword) {
    return true;
  }
  if (node.kind === ts.SyntaxKind.FalseKeyword) {
    return false;
  }
  if (node.kind === ts.SyntaxKind.NullKeyword) {
    return null;
  }

  throw literalError("value must be a JSON-like literal", node);
}

export function parseGeneratedLiteral(source, label = "generated literal") {
  const wrapped = `const __openBurnBarGeneratedLiteral = ${source};`;
  const sourceFile = ts.createSourceFile(label, wrapped, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);

  if (sourceFile.parseDiagnostics.length > 0) {
    const first = sourceFile.parseDiagnostics[0];
    throw new Error(`Could not parse ${label}: ${first.messageText}`);
  }
  if (sourceFile.statements.length !== 1 || !ts.isVariableStatement(sourceFile.statements[0])) {
    throw new Error(`Could not parse ${label}: expected exactly one literal expression`);
  }

  const declarations = sourceFile.statements[0].declarationList.declarations;
  if (declarations.length !== 1 || !declarations[0].initializer) {
    throw new Error(`Could not parse ${label}: missing literal initializer`);
  }

  return evaluateLiteral(declarations[0].initializer);
}
