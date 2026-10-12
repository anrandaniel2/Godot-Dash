// Asks the JavaScript engine running this script whether it accepts each
// wasm file. A wasm64 module fails validation on engines without memory64,
// so run this under a Node version whose V8 ships memory64 (Node 24+).
//
// usage: node tools/check_wasm_engine.mjs <file.wasm> [more.wasm ...]
import { readFileSync } from "node:fs";

let failed = false;
console.log(`engine: node ${process.version}`);
for (const file of process.argv.slice(2)) {
  const ok = WebAssembly.validate(readFileSync(file));
  console.log(`${file}: WebAssembly.validate=${ok}`);
  if (!ok) {
    failed = true;
    console.log(`::error::${file} is not accepted by this engine`);
  }
}
process.exitCode = failed ? 1 : 0;
