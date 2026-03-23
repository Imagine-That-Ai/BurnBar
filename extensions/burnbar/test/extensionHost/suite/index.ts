import * as path from "node:path";

import Mocha from "mocha";

export function run(): Promise<void> {
  const mocha = new Mocha({
    color: true,
    timeout: 30_000,
    ui: "tdd"
  });

  for (const fileName of ["localWorkspace.integration.js", "workspaceModes.integration.js"]) {
    mocha.addFile(path.resolve(__dirname, fileName));
  }

  return new Promise((resolve, reject) => {
    mocha.run((failures) => {
      if (failures > 0) {
        reject(new Error(`${failures} BurnBar extension-host test(s) failed.`));
        return;
      }

      resolve();
    });
  });
}
