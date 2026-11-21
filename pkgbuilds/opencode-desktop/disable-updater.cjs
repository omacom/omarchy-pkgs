// This package is updated by pacman. The upstream Linux updater downloads a
// Debian package, which cannot update an Arch installation. Fail the build if
// the compiled check moves or changes instead of silently re-enabling it.
const fs = require('node:fs')
const path = require('node:path')

const directory = path.join(process.argv[2], 'out/main')
let count = 0
for (const name of fs.readdirSync(directory)) {
  if (!name.endsWith('.js')) continue
  const file = path.join(directory, name)
  const original = fs.readFileSync(file, 'utf8')
  const patched = original.replace(/await\s+[\w$]+\.checkForUpdates\(\)/g, () => {
    count++
    return 'undefined /* Updated by pacman */'
  })
  if (original !== patched) fs.writeFileSync(file, patched)
}
if (count !== 1) throw new Error(`Expected one desktop update check, found ${count}; review the upstream updater`)
