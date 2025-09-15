// Simple renderer that compiles a Vega-Lite spec and writes SVG. Usage:
// node render-vega.js spec.json out.svg
const fs = require('fs')

async function main() {
  const args = process.argv.slice(2)
  if (args.length < 2) {
    console.error('Usage: node render-vega.js spec.json out.svg')
    process.exit(2)
  }
  const [specPath, outSvg] = args
  try {
    const vl = require('vega-lite')
    const vega = require('vega')
    const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'))
    const vg = vl.compile(spec).spec
    const view = new vega.View(vega.parse(vg), { renderer: 'none' }).initialize()
    const svg = await view.toSVG()
    fs.writeFileSync(outSvg, svg, 'utf8')
    console.log('Wrote', outSvg)
  } catch (err) {
    console.error('Render failed:', err && err.stack ? err.stack : err)
    process.exit(1)
  }
}

main()
