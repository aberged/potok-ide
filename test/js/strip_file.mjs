// `node test/js/strip_file.mjs <in> <out>`: what assets/js/strip_metadata.js
// makes of a file on disk, for the ImageMagick check in
// test/potok_ide_web/strip_metadata_js_test.exs.
import { readFile, writeFile } from "node:fs/promises"
import { basename } from "node:path"

import { stripMetadata } from "../../assets/js/strip_metadata.js"

const [input, output] = process.argv.slice(2)
const file = new File([await readFile(input)], basename(input), { type: "image/jpeg" })
const stripped = await stripMetadata(file)
await writeFile(output, new Uint8Array(await stripped.arrayBuffer()))
console.log(stripped === file ? "same" : "stripped")
