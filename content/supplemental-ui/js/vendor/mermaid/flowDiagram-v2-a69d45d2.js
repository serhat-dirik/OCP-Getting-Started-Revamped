import { p as e, f as o } from "./flowDb-72621fe2.js";
import { f as t, g as a } from "./styles-9f9379cd.js";
import { u as i } from "./mermaid-b1704b0f.js";
import "./graph-a5cd6100.js";
import "./index-7fdd4085.js";
import "./layout-6f90a841.js";
import "./clone-9569b997.js";
import "./edges-8700df07.js";
import "./createText-4dbd4ca1.js";
import "./line-8f37694c.js";
import "./array-2ff2c7a6.js";
import "./path-428ebac9.js";
import "./channel-7f9aae89.js";
const M = {
  parser: e,
  db: o,
  renderer: t,
  styles: a,
  init: (r) => {
    r.flowchart || (r.flowchart = {}), r.flowchart.arrowMarkerAbsolute = r.arrowMarkerAbsolute, i({ flowchart: { arrowMarkerAbsolute: r.arrowMarkerAbsolute } }), t.setConf(r.flowchart), o.clear(), o.setGen("gen-2");
  }
};
export {
  M as diagram
};
